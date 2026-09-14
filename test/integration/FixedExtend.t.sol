// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title FixedExtendTest
/// @notice A live loan must accept a finite extension up to the remaining room under the maximum
/// term. Passing `type(uint256).max` still fills that room in one shot.
contract FixedExtendTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1_000e18;

    function setUp() public {
        _deployCap();
    }

    function _ready() internal returns (FixedMarket market) {
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
    }

    function test_extend_liveLoanByFiniteTerm() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        uint256 expiryBefore = market.expiry(id);
        uint256 debtBefore = market.debt(id);

        vm.prank(defaultBorrower);
        uint256 actual = market.extend(id, 7 days);

        assertEq(actual, 7 days, "returns the requested extension");
        assertEq(market.expiry(id), expiryBefore + 7 days, "expiry moves by 7 days");
        assertGt(market.debt(id), debtBefore, "premium charged on the extension");
    }

    function test_extend_liveLoanMaxFillsRemainingRoom() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.prank(defaultBorrower);
        uint256 actual = market.extend(id, type(uint256).max);

        assertEq(actual, 29 days, "max term is 30 days, 1 day already used");
        assertEq(market.expiry(id), block.timestamp + 30 days, "capped at maximum term");
    }

    function test_extend_liveLoanBeyondRemainingRoom_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extend(id, 30 days);
    }

    function test_borrowMaxTermFillsTheMaximum() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, type(uint256).max);

        assertEq(market.expiry(id), block.timestamp + 30 days);
        assertEq(market.totalDebt(), market.debt(id));
        assertGt(market.availableCredit(10 days), 0);
        assertEq(market.availableCredit(365 days), market.availableCredit(30 days));
    }

    function test_borrowMore_onALiveLoan() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days);
        uint256 debtBefore = market.debt(id);

        vm.prank(defaultBorrower);
        uint256 added = market.borrowMore(id, defaultBorrower, 100e18);

        assertGt(added, 0);
        assertGt(market.debt(id), debtBefore);
    }

    function test_borrowMore_afterExpiry_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);
        skip(2 days);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.LoanExpired.selector);
        market.borrowMore(id, defaultBorrower, 1e18);
    }

    function test_borrowMore_whenRemainingTermBelowMinimum_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);
        skip(1 hours);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.borrowMore(id, defaultBorrower, 1e18);
    }

    function test_liquidate_unhealthyFixedLoan() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days);

        _setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27);

        uint256 max = market.maxLiquidatable();
        assertGt(max, 0);
        _mintStable(defaultLiquidator, max);

        uint256 debtBefore = market.debt(id);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(id, defaultLiquidator, max);

        assertGt(repaid, 0);
        assertGt(slashed, 0);
        assertEq(market.debt(id), debtBefore - repaid);
    }
}
