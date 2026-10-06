// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
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
        _setMaxCapital(market, 10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
    }

    function test_extend_liveLoanByFiniteTerm() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days, type(uint256).max);

        uint256 expiryBefore = market.expiry(id);
        uint256 debtBefore = market.debt(id);

        vm.prank(defaultBorrower);
        uint256 actual = market.extend(id, 7 days, type(uint256).max);

        assertEq(actual, 7 days, "returns the requested extension");
        assertEq(market.expiry(id), expiryBefore + 7 days, "expiry moves by 7 days");
        assertGt(market.debt(id), debtBefore, "premium charged on the extension");
    }

    function test_extend_liveLoanMaxFillsRemainingRoom() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days, type(uint256).max);

        vm.prank(defaultBorrower);
        uint256 actual = market.extend(id, type(uint256).max, type(uint256).max);

        assertEq(actual, 29 days, "max term is 30 days, 1 day already used");
        assertEq(market.expiry(id), block.timestamp + 30 days, "capped at maximum term");
    }

    function test_extend_liveLoanBeyondRemainingRoom_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days, type(uint256).max);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extend(id, 30 days, type(uint256).max);
    }

    function test_borrowMax_withNoCredit_reverts() public {
        (address marketAddr,,) = _createFixedMarket("Empty");
        FixedMarket market = FixedMarket(marketAddr);

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.borrow(defaultBorrower, type(uint256).max, 1 days, type(uint256).max);
    }

    function test_borrowMaxTermFillsTheMaximum() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, type(uint256).max, type(uint256).max);

        assertEq(market.expiry(id), block.timestamp + 30 days);
        assertEq(market.totalDebt(), market.debt(id));
        assertGt(market.maxPrincipal(10 days), 0);
        assertEq(market.maxPrincipal(365 days), market.maxPrincipal(30 days));
    }

    function test_borrowMore_onALiveLoan() public {
        FixedMarket market = _ready();

        uint256 term = 10 days;
        (uint256 openLiq, uint256 openUw) = market.premiumForBorrow(PRINCIPAL, term);
        vm.expectEmit(address(market));
        emit IFixedMarket.BorrowFixed(0, defaultBorrower, term, PRINCIPAL, openLiq + openUw);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, term, type(uint256).max);
        uint256 debtBefore = market.debt(id);

        uint256 remaining = market.expiry(id) - block.timestamp;
        uint256 addOn = 100e18;
        (uint256 moreLiq, uint256 moreUw) = market.premiumForBorrow(addOn, remaining);
        vm.expectEmit(address(market));
        emit IFixedMarket.BorrowMoreFixed(id, defaultBorrower, remaining, addOn, moreLiq + moreUw);
        vm.prank(defaultBorrower);
        uint256 added = market.borrowMore(id, defaultBorrower, addOn, type(uint256).max);

        assertGt(added, 0);
        assertGt(market.debt(id), debtBefore);
    }

    function test_borrowMore_afterExpiry_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days, type(uint256).max);
        skip(2 days);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.LoanExpired.selector);
        market.borrowMore(id, defaultBorrower, 1e18, type(uint256).max);
    }

    /// @dev Confirmed: `extend` on an unused id populated expiry from timestamp-0 arrears, then
    /// `borrowMore` minted debt while `loanCount` stayed zero. Keepers walking `[0, loanCount)`
    /// would never see it.
    function test_lifecycle_rejectsAnIdOutsideLoanCount() public {
        FixedMarket market = _ready();
        assertEq(market.loanCount(), 0);

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, 0));
        market.extend(0, 7 days, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, 0));
        market.extendAdmin(0, 7 days, type(uint256).max);

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, 0));
        market.borrowMore(0, defaultBorrower, 1e18, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, 0));
        market.repay(0, 1e18);

        assertEq(market.loanCount(), 0, "no loan was created");
        assertEq(market.totalDebt(), 0, "and no debt escaped the range");
        assertEq(market.expiry(0), 0, "expiry stayed unset");
    }

    function test_lifecycle_rejectsAnIdPastTheLastLoan() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);
        assertEq(market.loanCount(), 1);

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanNotFound.selector, 1));
        market.borrowMore(1, defaultBorrower, 1e18, type(uint256).max);
    }

    /// @dev Fully repaid loans stay in `loanCount` so keepers can walk them, but they cannot
    /// reopen. A new draw goes through {borrow}.
    function test_fullyRepaidLoanCannotReopen() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);
        uint256 owed = market.debt(id);
        _depositStable(defaultBorrower, owed);

        vm.prank(defaultBorrower);
        market.repay(id, type(uint256).max);

        assertEq(market.debt(id), 0);
        assertEq(market.loanCount(), 1, "the closed loan stays enumerable");
        assertEq(market.totalDebt(), 0);

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanClosed.selector, id));
        market.borrowMore(id, defaultBorrower, 1e18, type(uint256).max);

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanClosed.selector, id));
        market.extend(id, 1 days, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.LoanClosed.selector, id));
        market.extendAdmin(id, 7 days, type(uint256).max);

        vm.prank(defaultBorrower);
        (uint256 next,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);
        assertEq(next, 1, "a new loan takes the next id");
        assertEq(market.loanCount(), 2);
    }

    function test_borrowMore_whenRemainingTermBelowMinimum_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days, type(uint256).max);
        skip(1 hours);

        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.borrowMore(id, defaultBorrower, 1e18, type(uint256).max);
    }

    function test_extend_whenUnhealthy_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);

        _setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27);

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.Unhealthy.selector);
        market.extend(id, 1 days, type(uint256).max);
    }

    function test_liquidate_unhealthyFixedLoan() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);

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

    /// @dev A maximum short loan extended in the same block must not end up with more debt than
    /// a direct borrow to the same expiry could, so the extension is held to the credit limit.
    function test_extend_cannotBypassTheBufferedCreditLimit() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, 1 days, type(uint256).max);
        assertLe(market.totalDebt(), market.creditLimit(), "a maximum draw fits the limit");

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.extend(id, type(uint256).max, type(uint256).max);

        // paying down makes room for the extension premium
        uint256 paydown = market.debt(id) / 20;
        vm.prank(defaultBorrower);
        market.repay(id, paydown);

        vm.prank(defaultBorrower);
        market.extend(id, 7 days, type(uint256).max);
        assertLe(market.totalDebt(), market.creditLimit(), "the extension stays within the limit");
    }

    /// @dev The keeper's overdue roll is not held to the credit limit, so a loan at the limit can
    /// still be rolled and charged its arrears.
    function test_extendAdmin_rollsALoanAtTheCreditLimit() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, 1 days, type(uint256).max);
        vm.warp(market.expiry(id) + market.grace());

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.extend(id, 7 days, type(uint256).max);

        market.extendAdmin(id, 7 days, type(uint256).max);
        assertGt(market.totalDebt(), market.creditLimit(), "arrears and the roll are charged regardless");
    }

    /// @dev A floating borrow just before an extension raises the utilization it is priced at,
    /// at no cost if repaid in the same block. A quoted cap turns that into a revert.
    function test_extend_maxPremiumStopsAFloatingBorrowSandwich() public {
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        _depositStable(makeAddr("saver"), 10_000e18);
        FixedMarket market = _ready();
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 10 days, type(uint256).max);
        vm.warp(block.timestamp + 1 days);

        (uint256 liquidity, uint256 underwriting) = market.premiumForExtension(market.debt(id), 7 days);
        uint256 quoted = liquidity + underwriting;

        MarketBundle memory floating = _createReadyMarket("Floating");
        _setMaxCapital(floating.market, 100_000e18);
        _fundTranche(floating.tranche0Addr, makeAddr("floating supplier"), 100_000e18);
        uint256 credit = floating.market.availableCredit();
        assertGt(credit, 5 * PRINCIPAL, "enough floating credit to move utilization");
        vm.prank(defaultBorrower);
        floating.market.borrow(defaultBorrower, credit);

        (liquidity, underwriting) = market.premiumForExtension(market.debt(id), 7 days);
        uint256 inflated = liquidity + underwriting;
        assertGt(inflated, quoted, "the floating credit is priced into the extension");

        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.PremiumExceedsLimit.selector, inflated, quoted));
        market.extend(id, 7 days, quoted);

        vm.prank(defaultBorrower);
        floating.market.repay(type(uint256).max);

        uint256 debtBefore = market.debt(id);
        vm.prank(defaultBorrower);
        market.extend(id, 7 days, quoted);
        assertLe(market.debt(id) - debtBefore, quoted, "charged no more than the quote");
    }
}
