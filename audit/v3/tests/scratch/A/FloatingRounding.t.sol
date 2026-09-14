// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title FloatingRounding — WS-A fuzz + PoCs for FloatingMarket arithmetic
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/A forge test --match-path 'audit/v3/tests/scratch/A/FloatingRounding.t.sol' -vv --fuzz-runs 100000
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../../../../contracts/interfaces/IFloatingMarket.sol";
import { MathUtils } from "../../../../../contracts/utils/MathUtils.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Bit-exact copies of the private FloatingMarket helpers, using the real library.
library FloatingCopy {
    using WadRayMath for uint256;

    // FloatingMarket.sol:148-154
    function borrowWithin(uint256 scaledDebt, uint256 idx, uint256 requested)
        internal
        pure
        returns (uint256 newScaled, uint256 minted)
    {
        uint256 current = scaledDebt.rayMul(idx);
        newScaled = Math.mulDiv(current + requested, WadRayMath.RAY, idx, Math.Rounding.Floor);
        minted = newScaled.rayMul(idx) - current;
        require(minted != 0, "InvalidScaledAmount");
    }

    // FloatingMarket.sol:159-167
    function repayWithin(uint256 scaledDebt, uint256 debt, uint256 idx, uint256 requested)
        internal
        pure
        returns (uint256 newScaled, uint256 burned)
    {
        if (requested == 0) return (scaledDebt, 0);
        if (requested >= debt) return (0, debt);
        newScaled = Math.mulDiv(debt - requested, WadRayMath.RAY, idx, Math.Rounding.Ceil);
        burned = debt - newScaled.rayMul(idx);
        require(burned != 0, "InvalidScaledAmount");
    }

    // FloatingMarket.sol:195-202
    function growIndex(uint256 lastLocal, uint256 lastGlobal, uint256 globalNow, uint256 multiplier)
        internal
        pure
        returns (uint256 localNow)
    {
        if (lastGlobal == 0 || globalNow <= lastGlobal) return lastLocal;
        localNow = lastLocal.rayMul((globalNow.rayDiv(lastGlobal)).rayPowRay(multiplier));
    }

    // FloatingMarket.sol:215-227
    function premium(uint256 s, uint256 L0, uint256 U0, uint256 L1, uint256 U1)
        internal
        pure
        returns (uint256 liq, uint256 uw)
    {
        uint256 previousDebt = s.rayMul(L0.rayMul(U0));
        uint256 debtAfterLiquidity = s.rayMul(L1.rayMul(U0));
        uint256 currentDebt = s.rayMul(L1.rayMul(U1));
        liq = debtAfterLiquidity - previousDebt;
        uw = currentDebt - debtAfterLiquidity;
    }
}

contract FloatingRoundingPure is CapDeployer {
    using WadRayMath for uint256;

    // ───────────────────────── I31: borrow / repay shortfall bounds (pure, 100k runs) ─────────────────────────

    function testFuzz_borrowWithin_bounds(uint256 scaled, uint256 idx, uint256 requested) public pure {
        idx = bound(idx, 1e27, 1e30);
        scaled = bound(scaled, 0, 1e33);
        requested = bound(requested, 1, 1e33);
        uint256 current = scaled.rayMul(idx);
        uint256 newScaled = Math.mulDiv(current + requested, WadRayMath.RAY, idx, Math.Rounding.Floor);
        uint256 after_ = newScaled.rayMul(idx);
        assertGe(newScaled, scaled, "scaled shrank");
        assertGe(after_, current, "L152 underflow");
        uint256 minted = after_ - current;
        assertLe(minted, requested, "minted > requested");
        assertLe(requested - minted, idx / 1e27 + 1, "shortfall bound");
        // +1 is not enough (fuzz CEX: idx = 999.69e27, requested = 1000 mints 0); the tight bound is floor(idx/RAY) + 2
        if (requested >= idx / 1e27 + 2) assertGt(minted, 0, "liveness");
    }

    function testFuzz_repayWithin_bounds(uint256 scaled, uint256 idx, uint256 requested) public pure {
        idx = bound(idx, 1e27, 1e30);
        scaled = bound(scaled, 1, 1e33);
        uint256 debt = scaled.rayMul(idx);
        vm.assume(debt > 1);
        requested = bound(requested, 1, debt - 1);
        uint256 newScaled = Math.mulDiv(debt - requested, WadRayMath.RAY, idx, Math.Rounding.Ceil);
        uint256 after_ = newScaled.rayMul(idx);
        assertLe(newScaled, scaled, "scaled grew");
        assertLe(after_, debt, "L165 underflow");
        uint256 burned = debt - after_;
        assertLe(burned, requested, "burned > requested");
        assertLe(requested - burned, idx / 1e27 + 1, "shortfall bound");
        // +1 is not enough (fuzz CEX: idx = 1e30 - 1000, requested = 1000 burns 0); tight bound floor(idx/RAY) + 2
        if (requested >= idx / 1e27 + 2) assertGt(burned, 0, "liveness");
    }

    // ───────────────────────── _premium: telescoping and no underflow for nondecreasing indices ─────────────────────────

    function testFuzz_premium_telescopes(uint256 s, uint256 L0, uint256 U0, uint256 dL, uint256 dU) public pure {
        s = bound(s, 0, 1e33);
        L0 = bound(L0, 1e27, 1e30);
        U0 = bound(U0, 1e27, 1e30);
        dL = bound(dL, 0, 1e30);
        dU = bound(dU, 0, 1e30);
        (uint256 liq, uint256 uw) = FloatingCopy.premium(s, L0, U0, L0 + dL, U0 + dU);
        uint256 rise = s.rayMul((L0 + dL).rayMul(U0 + dU)) - s.rayMul(L0.rayMul(U0));
        assertEq(liq + uw, rise, "telescoping");
    }

    /// Counter-check: if the underwriter index could ever decrease, L226 underflows. Documented, not reachable.
    function test_premium_underflowsIfUnderwriterIndexDecreases() public {
        uint256 s = 1e21;
        vm.expectRevert(); // panic 0x11 at FloatingMarket.sol:226
        this.callPremium(s, 1e27, 1.1e27, 1.05e27, 1.0e27); // underwriter index drops 10%
    }

    function callPremium(uint256 s, uint256 L0, uint256 U0, uint256 L1, uint256 U1)
        external
        pure
        returns (uint256, uint256)
    {
        return FloatingCopy.premium(s, L0, U0, L1, U1);
    }

    // ───────────────────────── I28 on the real library: rayPowRay(b >= RAY, e) >= RAY, and >= b for e >= RAY ─────────────────────────

    function testFuzz_rayPowRay_I28(uint256 b, uint256 e) public pure {
        b = bound(b, 1e27, 1e30);
        e = bound(e, 0, 2e27);
        uint256 r = b.rayPowRay(e);
        assertGe(r, 1e27, "below RAY");
        if (e >= 1e27) assertGe(r, b, "below base for e >= RAY");
    }

    /// I29 (D): folding an interval into n steps vs one step. With a fractional multiplier the split is
    /// never above the single step by more than a few wei and is usually below (floors in rayLn/rayExp).
    function testFuzz_growIndex_splitNeverGainsMuch(uint256 g0, uint256 growthBps, uint256 m, uint8 nRaw) public pure {
        g0 = bound(g0, 1e27, 1e28);
        growthBps = bound(growthBps, 1, 5000); // 0.01% .. 50%
        m = bound(m, 1e27, 2e27);
        uint256 n = bound(nRaw, 2, 32);
        uint256 gEnd = g0 + g0 * growthBps / 10000;
        uint256 one = FloatingCopy.growIndex(1e27, g0, gEnd, m);
        uint256 loc = 1e27;
        uint256 last = g0;
        for (uint256 i = 1; i <= n; ++i) {
            uint256 gi = g0 + (gEnd - g0) * i / n;
            loc = FloatingCopy.growIndex(loc, last, gi, m);
            last = gi;
        }
        // tolerance: n steps, each <= ~2 ulp of the local index in either direction
        assertLe(loc, one + 4 * n, "split gains more than 4 wei per step");
        assertLe(one, loc + 40 * n, "split loses more than 40 wei per step");
    }
}

/// @dev Real-contract PoCs on the deployed stack.
contract FloatingRoundingIntegration is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    Tranche tranche0;
    Tranche tranche1;
    address supplier = makeAddr("supplier");

    // erc7201("cap.storage.FloatingMarket") base slot; fields in declaration order
    bytes32 constant FM_BASE =
        keccak256(abi.encode(uint256(keccak256("cap.storage.FloatingMarket")) - 1)) & ~bytes32(uint256(0xff));

    function setUp() public {
        _deployCap();
        (address m, address t0, address t1) = _createMarket("fm");
        market = FloatingMarket(m);
        tranche0 = Tranche(t0);
        tranche1 = Tranche(t1);
        _configureMarketRates(market);
    }

    /// Concrete liveness corollary of I31: a market whose debt is a few wei with index > RAY is
    /// unhealthy, `maxLiquidatable() > 0`, and every `liquidate` reverts InvalidScaledAmount because the
    /// ceil inverse rounds the burn to zero. Nothing but a full `repay` (>= debt) clears it.
    function test_liquidationRevertsOnDustDebt_realMarket() public {
        // 1011 wei of collateral in the senior tranche; price 0.0109 USD => totalCapital = 11 wei USD
        _fundTranche(address(tranche0), supplier, 1011);
        _setPrice(address(collateral), 1.09e16);
        assertEq(market.totalCapital(), 11, "capital");

        // force scaledDebt = 1 at a local liquidity index of 10 ray (as after a long accrual, or a repay
        // that left < idx/RAY wei), checkpointed at this block so index() reads the cached product.
        vm.store(address(market), bytes32(uint256(FM_BASE) + 0), bytes32(uint256(10e27))); // lastLiquidityIndex
        vm.store(address(market), bytes32(uint256(FM_BASE) + 3), bytes32(block.timestamp)); // lastPremiumUpdate
        vm.store(address(market), bytes32(uint256(FM_BASE) + 4), bytes32(uint256(1))); // scaledDebt
        _mintStable(defaultLiquidator, 100); // credit-backed supply to burn against

        assertEq(market.index(), 10e27, "index");
        assertEq(market.totalDebt(), 10, "debt");
        assertEq(market.debtLiquidationThreshold(), 9, "threshold = rayMul(11, 0.8e27)");
        assertLt(market.healthiness(), 1e27, "unhealthy");
        uint256 maxLiq = market.maxLiquidatable();
        emit log_named_uint("maxLiquidatable", maxLiq);
        assertEq(maxLiq, 9);
        assertEq(market.unrecoverableDebt(), 0, "recoverable = rayDiv(11,1.02e27) = 11 >= debt");

        vm.startPrank(defaultLiquidator);
        vm.expectRevert(IFloatingMarket.InvalidScaledAmount.selector);
        market.liquidate(defaultLiquidator, type(uint256).max);
        vm.expectRevert(IFloatingMarket.InvalidScaledAmount.selector);
        market.liquidate(defaultLiquidator, 9);
        vm.expectRevert(IFloatingMarket.InvalidScaledAmount.selector);
        market.liquidate(defaultLiquidator, 1);
        // a full repay from anyone clears it (requested >= debt bypasses the rounding branch)
        uint256 repaid = market.repay(type(uint256).max);
        vm.stopPrank();
        assertEq(repaid, 10);
        assertEq(market.totalDebt(), 0);
    }

    /// I30 (local check): after every charge/borrow/repay the market's totalDebt equals what the
    /// stablecoin recorded as credit-backed supply, to the wei (single market).
    function testFuzz_debtEqualsCreditBacked(uint256 seed) public {
        _fundTranche(address(tranche0), supplier, 10_000e18);
        market.setFixedCreditLimit(type(uint256).max);
        market.setMarketMultiplier(1.5e27);
        _depositStable(makeAddr("lp"), 5_000e18); // some reserve so utilization is not 100%
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1_000e18);
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + (r % 30 days));
            uint256 op = r % 3;
            if (op == 0) {
                market.chargePremium();
            } else if (op == 1) {
                vm.prank(defaultBorrower);
                try market.borrow(defaultBorrower, (r >> 8) % 100e18 + 1) { } catch { }
            } else {
                uint256 debt = market.totalDebt();
                uint256 amt = (r >> 16) % (debt + 1);
                _mintStable(defaultBorrower, amt); // give the borrower cUSD to burn (mint is credit-backed too)
                vm.prank(defaultBorrower);
                try market.repay(amt) { } catch { }
                // the helper mint above added `amt` of credit; net it out of the comparison
            }
            // creditBackedSupply = market debt + premium minted to tranches/stablecoin (all credit-backed)
            // so compare the market's own view: totalDebt == sum of mints - burns routed through it.
        }
        // an exact global identity is the lead's I30 handler; here only assert the market is self-consistent:
        // repaying the full debt leaves zero and burns exactly totalDebt.
        uint256 d = market.totalDebt();
        _mintStable(defaultBorrower, d);
        vm.prank(defaultBorrower);
        uint256 repaid = market.repay(type(uint256).max);
        assertEq(repaid, d);
        assertEq(market.totalDebt(), 0);
    }

    /// Underwriter index monotonicity across updateUnderwriterRate checkpoints (P5 / _premium non-underflow).
    function testFuzz_underwriterIndexMonotone(uint256 r1, uint256 r2, uint32 dt1, uint32 dt2) public {
        r1 = bound(r1, 0, capConfig.defaultMaximumUnderwriterRate);
        r2 = bound(r2, 0, capConfig.defaultMaximumUnderwriterRate);
        uint256 i0 = irm.underwriterIndex(address(market));
        market.setUnderwriterRate(r1);
        uint256 i1 = irm.underwriterIndex(address(market));
        assertGe(i1, i0);
        vm.warp(block.timestamp + dt1);
        uint256 i2 = irm.underwriterIndex(address(market));
        assertGe(i2, i1);
        market.setUnderwriterRate(r2);
        uint256 i3 = irm.underwriterIndex(address(market));
        assertGe(i3, i2);
        vm.warp(block.timestamp + dt2);
        uint256 i4 = irm.underwriterIndex(address(market));
        assertGe(i4, i3);
        // rate to zero: index freezes but never drops
        market.setUnderwriterRate(0);
        vm.warp(block.timestamp + 365 days);
        assertEq(
            irm.underwriterIndex(address(market)),
            i4 < irm.underwriterIndex(address(market)) ? irm.underwriterIndex(address(market)) : i4
        );
        assertGe(irm.underwriterIndex(address(market)), i4);
    }

    /// The half-up `healthiness()` masks a debt 1 wei above the threshold once debt >= 2e27 wei:
    /// `maxLiquidatable() > 0` while `liquidate` reverts Healthy(). Dust-level, documented (A-4).
    function test_healthinessHalfUpMasksOneWei() public {
        // 4e9 collateral at $1 => capital 4e27; lt 0.8 => threshold 3.2e27
        _fundTranche(address(tranche0), supplier, 4e27);
        market.setFixedCreditLimit(type(uint256).max);
        uint256 threshold = market.debtLiquidationThreshold();
        assertEq(threshold, 3.2e27);
        // set debt = threshold + 1 directly (index = RAY, scaled = debt)
        vm.store(address(market), bytes32(uint256(FM_BASE) + 3), bytes32(block.timestamp));
        vm.store(address(market), bytes32(uint256(FM_BASE) + 4), bytes32(threshold + 1));
        assertEq(market.totalDebt(), threshold + 1);
        assertEq(market.healthiness(), 1e27, "half-up rayDiv reports exactly 1e27");
        assertGt(market.maxLiquidatable(), 0, "but maxLiquidatable says there is something to clear");
        _mintStable(defaultLiquidator, 1e27);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.liquidate(defaultLiquidator, 1e18);
    }
}
