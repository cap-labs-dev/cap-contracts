// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockReentrantERC20 } from "../shared/mocks/MockReentrantERC20.sol";

import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title LiquidationReentrancyTest
/// @notice Liquidation is the one place the protocol hands control to the collateral token, and it
/// does so with its own books half-written.
///
/// {BaseMarket-_liquidate} pays the liquidator out of the tranches and the market records the debt
/// it cleared afterwards, which is deliberate: the health gate and the {maxLiquidatable} cap are
/// both measured against {IBaseMarket-totalDebt} as it stands, so clearing first would make the
/// cap a no-op. The consequence is a window, opened by the collateral transfer, in which the
/// market still reads as owing the full amount. {ITranche-slash} had the same shape around its
/// kill latch. These cases run a market on a collateral token that calls back from inside its own
/// transfer and check what that callback can do with the window.
contract LiquidationReentrancyTest is CapDeployer {
    /// @dev Revert data of a guard refusal. The error takes no arguments, so this is all of it
    bytes internal refusedByTheGuard =
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    MockReentrantERC20 internal hooked;
    FloatingMarket internal market;
    address internal senior;
    address internal junior;

    function setUp() public {
        _deployCap();

        hooked = new MockReentrantERC20("Hooked Ether", "hETH", 18);
        _setPrice(address(hooked), 2e18);

        address[] memory assets = new address[](2);
        assets[0] = address(hooked);
        assets[1] = address(hooked);

        (address marketAddr, address[] memory tranches) =
            _createMarket("Hooked", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(marketAddr);
        senior = tranches[0];
        junior = tranches[1];

        _setMarketSlopes(marketAddr);
        _setMaxCapital(market, 100_000e18);

        _fundTranche(senior, address(hooked), makeAddr("senior"), 500e18);
        _fundTranche(junior, address(hooked), makeAddr("junior"), 500e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);

        // $2000 of collateral against $900 of debt, then the threshold moves under it
        market.setLt(0.4e27);
        assertLt(market.healthiness(), 1e27, "the market has to be liquidatable for any of this");
    }

    // ── the market's debt write ───────────────────────────────────────────────

    /// @dev The damaging one, and the reason the guard covers the whole surface rather than
    /// {liquidate} alone. {FloatingMarket-repay} is permissionless, so the hook needs no role at
    /// all. Left open, a repayment made inside the window is measured against the pre-liquidation
    /// debt and then overwritten wholesale by the outer call's `scaledDebt` write — the borrower's
    /// cUSD is burnt and the debt it was meant to clear comes straight back.
    function test_repayCannotBeReenteredWhileALiquidationIsInFlight() public {
        _mintStable(address(hooked), 100e18);
        _mintStable(defaultLiquidator, 100e18);
        uint256 debtBefore = market.totalDebt();

        hooked.arm(address(market), abi.encodeCall(FloatingMarket.repay, (50e18)));

        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(defaultLiquidator, 100e18);

        assertTrue(hooked.reentered(), "the hook has to have fired, or this proves nothing");
        assertFalse(hooked.reentrySucceeded(), "and it has to have been turned away");
        assertEq(hooked.reentryReturn(), refusedByTheGuard, "by the guard, not by something incidental");

        assertEq(stablecoin.balanceOf(address(hooked)), 100e18, "no cUSD was burnt for a repayment that vanished");
        assertEq(market.totalDebt(), debtBefore - repaid, "and the debt moved by the liquidation alone");
    }

    /// @dev Re-entering {liquidate} itself clears and pays for the same debt twice, since the
    /// second call re-reads the cap against a debt the first has not yet written down.
    ///
    /// The role grant is the honest version of the precondition: {liquidate} is LIQUIDATOR-gated,
    /// so without it the inner call is turned away by the access check before the guard is
    /// reached, and the test would pass whether the guard existed or not. What it models is a
    /// liquidator that is itself the contract with the hook, which is the cheaper half of the
    /// setup — the expensive half is getting hooked collateral admitted by governance.
    function test_liquidateCannotBeReenteredByTheCollateralToken() public {
        _grantLiquidator(address(hooked));
        _mintStable(address(hooked), 200e18);
        _mintStable(defaultLiquidator, 100e18);

        hooked.arm(address(market), abi.encodeCall(FloatingMarket.liquidate, (address(hooked), 100e18)));

        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, 100e18);

        assertTrue(hooked.reentered(), "the hook fired");
        assertEq(hooked.reentryReturn(), refusedByTheGuard, "the second liquidation was refused by the guard");

        assertEq(repaid, 100e18, "one liquidation, one repayment");
        assertEq(slashed, 102e18, "and one payout, at the bonus");
        assertEq(hooked.balanceOf(address(hooked)), 0, "the token collected no collateral of its own");
        assertEq(stablecoin.balanceOf(address(hooked)), 200e18, "and burnt none of its cUSD");
    }

    /// @dev The other side of the guard, and the regression it actually risks. The guard is
    /// transient storage, which is cleared at the end of the transaction rather than the end of
    /// the call, so a version that took the flag and never released it would pass every test
    /// above and still break any caller batching two operations. Sequential is not nested: two
    /// liquidations in one transaction have to both go through.
    function test_sequentialLiquidationsInOneTransactionAreNotBlocked() public {
        _mintStable(defaultLiquidator, 200e18);

        vm.prank(defaultLiquidator);
        (uint256 firstRepaid,) = market.liquidate(defaultLiquidator, 50e18);

        vm.prank(defaultLiquidator);
        (uint256 secondRepaid,) = market.liquidate(defaultLiquidator, 50e18);

        assertEq(firstRepaid, 50e18, "the first went through");
        assertEq(secondRepaid, 50e18, "and so did the second, in the same transaction");
    }

    // ── the tranche's kill latch ──────────────────────────────────────────────

    /// @dev {ITranche-slash} closed the same window by ordering rather than by a guard: the latch
    /// is computed from the balance the withdrawal is about to leave behind, so it is already set
    /// when the token gets control. Probed with a view from inside the transfer, because that is
    /// the only moment the difference is observable — a killed tranche reports no room for a
    /// deposit, and with the latch written afterwards this would answer with the whole uint256
    /// while the asset base had already collapsed, which is the degenerate share price the latch
    /// exists to close.
    function test_theKillLatchIsAlreadySetWhenTheCollateralLeaves() public {
        // 1000 tokens at $0.10 is $100 against $900 of debt, so the liquidation drains a tranche
        _setPrice(address(hooked), 0.1e18);
        _mintStable(defaultLiquidator, 900e18);

        // the junior is slashed first, so its payout is the first transfer the hook sees
        hooked.arm(junior, abi.encodeCall(ITranche.maxDeposit, (makeAddr("depositor"))));

        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 900e18);

        assertTrue(hooked.reentered(), "the hook fired during the payout");
        assertTrue(hooked.reentrySucceeded(), "a view, so it answers rather than reverting");
        assertEq(abi.decode(hooked.reentryReturn(), (uint256)), 0, "already killed, so already refusing deposits");

        assertEq(ITranche(junior).totalAssets(), 0, "the tranche really was drained");
        assertTrue(ITranche(junior).killed(), "and stayed killed afterwards");
    }
}
