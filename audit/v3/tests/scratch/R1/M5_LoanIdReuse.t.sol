// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IFixedMarket } from "../../../../../contracts/interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// Round-3 port of round-1 M-5 (D9 / V_LoanIdReuse / R1_M5*). HEAD adds `_requireLoan`
/// (`id >= loanCount` -> LoanNotFound, FixedMarket.sol:212-214) and `_requireOpenLoan`
/// (`debt[id] == 0` -> LoanClosed, :219-222) on every id-taking function (:84, :93, :119, :128,
/// :143, :152). The round-1 exploit (seed an unused id via extend/extendAdmin, draw on it, let
/// the next `borrow` overwrite its expiry) is therefore closed at step 1. Each round-1 step is
/// asserted to revert with the new error, then the honest path is checked to charge the full term.
contract R1_M5_LoanIdReuse is CapDeployer {
    FixedMarket market;
    address tranche0;
    address owner = makeAddr("owner-only");
    address keeper = makeAddr("keeper-only");

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        irm.setTermMultiplierSlope(1e27);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        (address m, address[] memory ts) = _createFixedMarket("X", defaultMarketOwner, defaultBorrower, w);
        market = FixedMarket(m);
        tranche0 = ts[0];
        // a second, owner-only address on the market owner role (role admin is GOVERNOR = this)
        accessManager.grantRole(_operatorRoleOf(defaultMarketOwner), owner, 0);
        vm.startPrank(owner);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        vm.stopPrank();
        market.setFixedCreditLimit(type(uint256).max);
        _grantKeeper(keeper);
        _fundTranche(tranche0, makeAddr("uw"), 40_000_000e18);
        _depositStable(makeAddr("saver"), 40_000_000e18);
    }

    /// Round-1 step 1 (seed the unused id via `extend`) is refused. Note: on HEAD `extend` is a
    /// BORROWER selector after `setBorrowerRole` (Registry.sol:222), not an owner one.
    function test_borrowerCannotSeedPhantomId() public {
        uint256 id = market.loanCount();
        assertEq(market.expiry(id), 0);
        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.extend(id, 1 days);
    }

    /// Round-2 variant: keeper seeds via extendAdmin (expiry 0 + grace <= now) is refused.
    function test_keeperCannotSeedPhantomId() public {
        vm.warp(1_800_000_000);
        _setPrice(address(collateral), capConfig.collateralPrice);
        uint256 id = market.loanCount();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.extendAdmin(id, 1 days);
    }

    /// Borrower alone: borrowMore / repay / liquidate / writeOff on an unknown id all refuse.
    function test_unknownIdRefusedEverywhere() public {
        uint256 id = market.loanCount();
        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.borrowMore(id, defaultBorrower, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.repay(id, 1);
        vm.prank(defaultLiquidator);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.liquidate(id, defaultLiquidator, 1);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, id));
        market.writeOff(id);
    }

    /// A repaid loan cannot be reopened with a stale (cheap) expiry.
    function test_closedLoanCannotBeReopened() public {
        vm.prank(defaultBorrower);
        (uint256 id, uint256 p) = market.borrow(defaultBorrower, 1_000e18, 30 days);
        uint256 debt = market.debt(id);
        _depositStable(defaultBorrower, debt - p);
        vm.prank(defaultBorrower);
        market.repay(id, type(uint256).max);
        assertEq(market.debt(id), 0);
        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanClosed.selector, id));
        market.borrowMore(id, defaultBorrower, 1e18);
        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanClosed.selector, id));
        market.extend(id, 1 days);
    }

    /// `borrow` never reuses an id; each draw gets a fresh id with its own expiry.
    function test_borrowNeverReusesIds() public {
        vm.startPrank(defaultBorrower);
        (uint256 a,) = market.borrow(defaultBorrower, 1_000e18, 1 days);
        (uint256 b,) = market.borrow(defaultBorrower, 1_000e18, 30 days);
        vm.stopPrank();
        assertEq(b, a + 1);
        assertEq(market.expiry(a), block.timestamp + 1 days);
        assertEq(market.expiry(b), block.timestamp + 30 days);
    }

    /// Honest re-terming still costs the full term: borrow 1d then extend 29d charges the whole debt.
    function test_honestPathsAllChargeFullTerm() public {
        uint256 P = 10_000_000e18;
        (uint256 hl, uint256 hu) = market.premiumForBorrow(P, 30 days);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, P, 1 days);
        uint256 afterBorrow = market.debt(id);
        vm.prank(defaultBorrower);
        market.extend(id, 29 days);
        uint256 total = market.debt(id) - P;
        emit log_named_uint("honest 30d premium", hl + hu);
        emit log_named_uint("borrow 1d + extend 29d premium", total);
        assertGt(total - (afterBorrow - P), hu * 29 / 30, "extend charged the full debt for 29 days");
    }
}
