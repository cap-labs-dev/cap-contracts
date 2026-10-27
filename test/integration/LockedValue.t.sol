// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";

/// @title LockedValueTest
/// @notice The market computes locked capital in USD while tranches hold collateral tokens, so a
/// tranche has to price the locked value back into assets before deciding what is redeemable.
/// These cases use collateral away from $1 so a missing conversion cannot pass unnoticed.
contract LockedValueTest is CapDeployer {
    function _marketAtPrice(uint256 price) internal returns (FloatingMarket market, address senior, address junior) {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.collateralPrice = price;
        _deployCapWithConfig(cfg);

        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("M");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        _setMaxCapital(market, 100_000e18);
        _fundTranche(senior, makeAddr("senior"), 1_000e18);
        _fundTranche(junior, makeAddr("junior"), 1_000e18);
    }

    /// Collateral at $0.50: $500 of debt needs $714 of backing, more than the junior's entire $500
    /// of capital, so nothing in the junior may be redeemed.
    function test_juniorFullyLockedWhenBackingExceedsItsCapital() public {
        (FloatingMarket market,, address junior) = _marketAtPrice(0.5e18);
        assertEq(market.totalCapital(), 1_000e18, "2000 tokens at $0.50");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        // required backing value = debt / (lt - buffer) = 500 / 0.7
        assertApproxEqAbs(market.lockedValue(junior), 714285714285714285714, 1, "junior locks the whole requirement");
        assertGt(market.lockedValue(junior), Tranche(junior).totalCapital(), "requirement exceeds its capital");

        assertEq(Tranche(junior).unlockedSupply(), 0, "junior must be fully locked");
        assertEq(Tranche(junior).maxInstantRedeem(makeAddr("junior")), 0, "nothing redeemable");
    }

    /// An underwriter must never be able to exit collateral that is backing live debt, which shows
    /// up as the credit limit dropping below outstanding debt.
    function test_redemptionCannotPushCreditLimitBelowDebt() public {
        (FloatingMarket market,, address junior) = _marketAtPrice(0.5e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        uint256 redeemable = Tranche(junior).maxInstantRedeem(makeAddr("junior"));
        if (redeemable > 0) {
            vm.prank(makeAddr("junior"));
            Tranche(junior).instantRedeem(redeemable, makeAddr("junior"), makeAddr("junior"));
        }

        assertGe(market.creditLimit(), market.totalDebt(), "credit limit must still cover the debt");
    }

    /// Above $1 the senior has spare capacity once the junior covers the requirement, and the
    /// unlocked amount must be priced in tokens rather than dollars.
    function test_seniorUnlockedAmountIsPricedInTokens() public {
        (FloatingMarket market, address senior, address junior) = _marketAtPrice(2e18);
        assertEq(market.totalCapital(), 4_000e18, "2000 tokens at $2");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1_000e18);

        // requirement is 1000 / 0.7 = $1428.57; the junior holds $2000 so it absorbs all of it
        assertApproxEqAbs(market.lockedValue(junior), 1428571428571428571428, 1, "junior locks the requirement");
        assertEq(market.lockedValue(senior), 0, "junior alone covers it, senior is free");
        assertEq(Tranche(senior).unlockedSupply(), Tranche(senior).totalSupply(), "senior fully unlocked");

        // the junior locks $1428.57 of value = 714.29 tokens out of its 1000
        uint256 expectedUnlocked = 1_000e18 - 714285714285714285714;
        assertApproxEqAbs(Tranche(junior).unlockedSupply(), expectedUnlocked, 1e6, "junior unlocked in tokens");
    }

    /// @dev Keep the six-decimal exit-rounding regression at the minimum permitted buffer.
    /// Both conversions must ceil so the remaining collateral also covers the buffered credit bound.
    function test_sixDecimalMinimumBufferWithdrawCannotBreakHealth() public {
        _deployCap();
        MockERC20 usdc = _newCollateral("USD Coin", "USDC", 6, 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);

        (address marketAddr, address[] memory tranches) =
            _createMarket("usdc6", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        FloatingMarket market = FloatingMarket(marketAddr);
        market.setBuffer(0.1e27);
        market.setLoanToValue(market.liquidationThreshold() - market.buffer());
        _setMaxCapital(market, type(uint256).max);

        address seniorLp = makeAddr("senior-lp");
        address juniorLp = makeAddr("junior-lp");
        _fundTranche(tranches[0], address(usdc), seniorLp, 1_000e6);
        _fundTranche(tranches[1], address(usdc), juniorLp, 4_001e6);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 3_200e18 + 1);

        _exitUnlocked(tranches[0], seniorLp);
        _exitUnlocked(tranches[1], juniorLp);

        emit log_named_uint("health", market.healthiness());
        emit log_named_uint("debt  ", market.totalDebt());
        emit log_named_uint("capital", market.totalCapital());
        assertGe(market.healthiness(), 1e27, "a full instant exit must not make the market unhealthy");
        assertGe(market.creditLimit(), market.totalDebt(), "ceil exits preserve the buffered credit bound");
    }

    function _exitUnlocked(address tranche, address lp) internal {
        uint256 redeemable = Tranche(tranche).maxInstantRedeem(lp);
        if (redeemable == 0) return;
        vm.prank(lp);
        Tranche(tranche).instantRedeem(redeemable, lp, lp);
    }

    /// No debt means nothing is locked, at any price.
    function test_noDebtLeavesEverythingUnlocked() public {
        (FloatingMarket market, address senior, address junior) = _marketAtPrice(0.5e18);
        assertEq(market.totalDebt(), 0, "no debt");
        assertEq(market.lockedValue(senior), 0, "senior free");
        assertEq(market.lockedValue(junior), 0, "junior free");
        assertEq(Tranche(junior).unlockedSupply(), Tranche(junior).totalSupply(), "all unlocked");
    }

    /// @dev Zero-debt locking used to walk the stack and price every junior. After the feed dies
    /// that walk reverted, so a senior could not exit even though nothing was locked.
    function test_noDebtUnlocksAfterTheFeedDies() public {
        (FloatingMarket market, address senior, address junior) = _marketAtPrice(0.5e18);
        oracle.setSource(Tranche(junior).asset(), new IOracle.Sources[](0));

        vm.expectRevert(ITranche.InvalidPrice.selector);
        Tranche(junior).totalCapital();

        assertEq(market.lockedValue(senior), 0, "senior free without a price");
        assertEq(market.lockedValue(junior), 0, "junior free without a price");
        assertEq(Tranche(senior).unlockedSupply(), Tranche(senior).totalSupply());
        assertEq(Tranche(junior).unlockedSupply(), Tranche(junior).totalSupply());

        _exitUnlocked(junior, makeAddr("junior"));
        assertEq(Tranche(junior).balanceOf(makeAddr("junior")), 0, "debt-free junior still exits");
    }

    /// lockedValue divides by liquidationThreshold - buffer, so the setters must keep the buffer
    /// below the threshold.
    function test_buffer_cannotBeRaisedToOrAboveLiquidationThreshold() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.liquidationThreshold(), 0.8e27, "fixture liquidationThreshold");

        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.8e27);

        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.9e27);

        market.setBuffer(0.79e27); // still valid
    }

    function test_liquidationThreshold_cannotBeDroppedToOrBelowBuffer() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.buffer(), 0.1e27, "fixture buffer");

        vm.expectRevert(IBaseMarket.InvalidLiquidationThreshold.selector);
        market.setLiquidationThreshold(1e27 + 1);

        vm.expectRevert(IBaseMarket.InvalidLiquidationThreshold.selector);
        market.setLiquidationThreshold(0.1e27);

        vm.expectRevert(IBaseMarket.InvalidLiquidationThreshold.selector);
        market.setLiquidationThreshold(0.05e27);

        // dropping the threshold below loanToValue is still allowed; that just makes the market unhealthy
        market.setLiquidationThreshold(0.2e27);
        assertLt(
            market.liquidationThreshold(),
            market.loanToValue(),
            "liquidationThreshold below loanToValue is a permitted guardian action"
        );
    }

    function test_targetHealth_atLeast1_25AndAboveLiquidationThreshold() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.liquidationThreshold(), 0.8e27, "fixture liquidationThreshold");
        assertEq(market.targetHealth(), 1.25e27, "fixture targetHealth");

        vm.expectRevert(IBaseMarket.InvalidTargetHealth.selector);
        market.setTargetHealth(1e27);

        vm.expectRevert(IBaseMarket.InvalidTargetHealth.selector);
        market.setTargetHealth(1.24e27);

        market.setTargetHealth(1.25e27);
        market.setTargetHealth(1.5e27);
        assertEq(market.targetHealth(), 1.5e27);

        market.setLiquidationThreshold(1e27);
        assertLt(
            market.liquidationThreshold(),
            market.targetHealth(),
            "liquidationThreshold stays strictly below targetHealth"
        );
    }

    /// @dev 500 of debt against 1,000 of the approved collateral in the senior, then the owner adds
    /// an uncapped junior in another oracle-listed asset and fills it past the senior's lock.
    function _swapSetup() internal returns (FloatingMarket market, address senior, address swap) {
        _deployCap();
        address marketAddr;
        (marketAddr, senior,) = _createMarket("M");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        _setMaxCapital(market, 100_000e18);
        _fundTranche(senior, makeAddr("senior"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.9e27;
        weights[1] = 0.05e27;
        weights[2] = 0.05e27;
        MockERC20 risky = _newCollateral("Risky", "RSK", 18, 1e18);
        swap = market.createTranche(address(risky), weights, 12 hours);
        _fundTranche(swap, address(risky), makeAddr("owner"), 1_000e18);
        assertEq(ITranche(swap).maxCapital(), 0, "governance has not priced the new asset in");
    }

    /// An uncapped junior cannot release the senior's collateral, so the debt stays on the asset
    /// governance approved for the market.
    function test_uncappedJuniorDoesNotUnlockTheSenior() public {
        (FloatingMarket market, address senior, address swap) = _swapSetup();
        assertGt(Tranche(swap).totalCapital(), 714.3e18, "the junior holds more than the requirement");

        // 500 / 0.7, none of it absorbed by the uncapped junior
        assertApproxEqAbs(market.lockedValue(senior), 714285714285714285715, 1, "the senior still locks it all");
        uint256 exitable = Tranche(senior).maxInstantRedeem(makeAddr("senior"));
        // the dead shares stay behind as well, since their backing never holds a lock
        assertApproxEqAbs(exitable, 1_000e18 - 714285714285714285715 - 1_000, 1, "only the excess can leave");

        vm.prank(makeAddr("senior"));
        vm.expectRevert();
        Tranche(senior).instantRedeem(exitable + 1, makeAddr("senior"), makeAddr("senior"));
    }

    /// The junior shields the tranches above it up to its cap and no further.
    function test_juniorShieldsUpToItsCap() public {
        (FloatingMarket market, address senior, address swap) = _swapSetup();
        uint256 required = market.lockedValue(senior);

        ITranche(swap).setMaxCapital(200e18);
        assertEq(market.lockedValue(senior), required - 200e18, "counted at its cap");

        ITranche(swap).setMaxCapital(100_000e18);
        assertEq(market.lockedValue(senior), 0, "a cap above its holdings counts them in full");

        ITranche(swap).setMaxCapital(0);
        assertEq(market.lockedValue(senior), required, "cutting the cap relocks the senior");
    }

    /// @dev The owner opens a junior with a single live share, donates so the dead shares own
    /// almost all of it, lets the senior leave on that backing, then tries to walk away from it.
    /// The dead shares' backing is unowned and valued at zero once no live share remains, so it
    /// must never count towards a lock either.
    function test_deadShareBackingCannotMeetALock() public {
        _deployCap();
        (address marketAddr, address senior,) = _createMarket("M");
        FloatingMarket market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        _setMaxCapital(market, 100_000e18);
        _fundTranche(senior, makeAddr("senior"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.9e27;
        weights[1] = 0.05e27;
        weights[2] = 0.05e27;
        MockERC20 risky = _newCollateral("Risky", "RSK", 18, 1e18);
        Tranche junior = Tranche(market.createTranche(address(risky), weights, 12 hours));
        junior.setMaxCapital(100_000e18);

        address owner = makeAddr("owner");
        _fundTranche(address(junior), address(risky), owner, 1_001);
        assertEq(junior.balanceOf(owner), 1, "one live share beside the dead ones");
        risky.mint(owner, 1_000e18);
        vm.startPrank(owner);
        assertTrue(risky.transfer(address(junior), 1_000e18));
        vm.stopPrank();

        // the junior now frees the senior, which leaves
        assertEq(market.lockedValue(senior), 0);
        _exitUnlocked(senior, makeAddr("senior"));
        assertGt(market.lockedValue(address(junior)), 0, "the junior carries the debt");

        // the last live share must stay: without it the backing is unowned and unslashable
        assertEq(junior.maxInstantRedeem(owner), 0, "the dead shares cannot hold the lock");
        vm.prank(owner);
        vm.expectRevert();
        junior.instantRedeem(1, owner, owner);
        assertGe(market.healthiness(), 1e27, "the debt stays backed");
    }
}
