// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title HalmosMath — Workstream A symbolic harness
/// @notice Single-op properties for halmos 0.3.3. Every `check_` function takes symbolic inputs,
/// bounds them with `vm.assume`, and asserts a property of the REAL WadRayMath library or of a
/// bit-exact copy of a private market/stablecoin function (copied because the originals are
/// `private`/`internal view` on storage; the copy is annotated with the source line it mirrors).
///
/// Run:  FOUNDRY_TEST=audit/v3/tests/scratch/A halmos --root . --contract HalmosMath --function check_ --loop 2
/// Bounds were reduced from uint128 to uint64 after the 128-bit run made no progress in 15 min (A.md §6).
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test } from "forge-std/Test.sol";

contract HalmosMath is Test {
    using WadRayMath for uint256;

    uint256 constant RAY = 1e27;
    uint256 constant HALF = 0.5e27;

    // ───────────────────────────── rayMul / rayDiv (WadRayMath.sol:58-79) ─────────────────────────────

    /// rayMul is round-half-up: |c*RAY - a*b| <= HALF_RAY, and the exact product is in [c*RAY-HALF, c*RAY+HALF).
    function check_rayMul_halfUp(uint256 a, uint256 b) public pure {
        vm.assume(a <= type(uint64).max && b <= type(uint64).max);
        uint256 c = a.rayMul(b);
        uint256 p = a * b;
        assert(c * RAY <= p + HALF);
        assert(p + HALF < c * RAY + RAY);
    }

    /// rayMul is monotone in each argument.
    function check_rayMul_monotone(uint256 a, uint256 b) public pure {
        vm.assume(a < type(uint64).max && b <= type(uint64).max);
        assert(a.rayMul(b) <= (a + 1).rayMul(b));
    }

    /// rayMul by a factor >= RAY never shrinks the argument (the I28 / _premium non-underflow lemma).
    function check_rayMul_geRay_noShrink(uint256 a, uint256 f) public pure {
        vm.assume(a <= type(uint64).max && f >= RAY && f <= type(uint96).max);
        assert(a.rayMul(f) >= a);
    }

    /// rayDiv is round-half-up: c = round(a*RAY/b).
    function check_rayDiv_halfUp(uint256 a, uint256 b) public pure {
        vm.assume(a <= type(uint64).max && b > 0 && b <= type(uint64).max);
        uint256 c = a.rayDiv(b);
        uint256 n = a * RAY;
        assert(c * b <= n + b / 2);
        assert(n + b / 2 < c * b + b);
    }

    /// rayDiv(a, b) >= RAY whenever a >= b (the _growIndex base lower bound).
    function check_rayDiv_geRay(uint256 a, uint256 b) public pure {
        vm.assume(b > 0 && b <= type(uint64).max && a >= b && a <= type(uint64).max);
        assert(a.rayDiv(b) >= RAY);
    }

    // ───────────────────────────── FloatingMarket._borrowWithin (FloatingMarket.sol:148-154) ─────────────────────────────

    function _borrowWithin(uint256 scaledDebt, uint256 idx, uint256 requested)
        internal
        pure
        returns (uint256 newScaled, uint256 minted)
    {
        uint256 current = scaledDebt.rayMul(idx); // L150
        newScaled = Math.mulDiv(current + requested, WadRayMath.RAY, idx, Math.Rounding.Floor); // L151
        minted = newScaled.rayMul(idx) - current; // L152  (would panic if newScaled.rayMul(idx) < current)
    }

    /// I31 (borrow side): minted <= requested, shortfall <= idx/RAY + 1, scaled debt never shrinks,
    /// and the subtraction at L152 cannot underflow. Domain: idx in [RAY, 1e29], scaled <= 1e33, requested in [1, 1e33].
    function check_borrowWithin_bounds(uint256 scaledDebt, uint256 idx, uint256 requested) public pure {
        vm.assume(idx >= RAY && idx <= 1e29);
        vm.assume(scaledDebt <= 1e33);
        vm.assume(requested >= 1 && requested <= 1e33);
        uint256 current = scaledDebt.rayMul(idx);
        uint256 newScaled = Math.mulDiv(current + requested, WadRayMath.RAY, idx, Math.Rounding.Floor);
        uint256 after_ = newScaled.rayMul(idx);
        assert(newScaled >= scaledDebt); // no shrink
        assert(after_ >= current); // L152 cannot underflow
        uint256 minted = after_ - current;
        assert(minted <= requested);
        assert(requested - minted <= idx / RAY + 1);
    }

    /// Liveness: a request of at least floor(idx/RAY) + 2 wei always mints something (no InvalidScaledAmount).
    /// (+1 is NOT enough: minted > requested - idx/RAY - 0.5, so a fractional ray part above 0.5 can zero it; fuzz CEX in A.md)
    function check_borrowWithin_liveness(uint256 scaledDebt, uint256 idx, uint256 requested) public pure {
        vm.assume(idx >= RAY && idx <= 1e29);
        vm.assume(scaledDebt <= 1e33);
        vm.assume(requested >= idx / RAY + 2 && requested <= 1e33);
        (, uint256 minted) = _borrowWithin(scaledDebt, idx, requested);
        assert(minted > 0);
    }

    // ───────────────────────────── FloatingMarket._repayWithin (FloatingMarket.sol:159-167) ─────────────────────────────

    /// I31 (repay side): burned <= requested, shortfall <= idx/RAY + 1, scaled debt never grows,
    /// and the subtraction at L165 cannot underflow. requested < debt (the rounding branch).
    function check_repayWithin_bounds(uint256 scaledDebt, uint256 idx, uint256 requested) public pure {
        vm.assume(idx >= RAY && idx <= 1e29);
        vm.assume(scaledDebt >= 1 && scaledDebt <= 1e33);
        uint256 debt = scaledDebt.rayMul(idx);
        vm.assume(requested >= 1 && requested < debt);
        uint256 newScaled = Math.mulDiv(debt - requested, WadRayMath.RAY, idx, Math.Rounding.Ceil); // L164
        uint256 after_ = newScaled.rayMul(idx);
        assert(newScaled <= scaledDebt);
        assert(after_ <= debt); // L165 cannot underflow
        uint256 burned = debt - after_;
        assert(burned <= requested);
        assert(requested - burned <= idx / RAY + 1);
    }

    /// Liveness: requested >= floor(idx/RAY) + 2 always burns something (+1 is not enough, see above).
    function check_repayWithin_liveness(uint256 scaledDebt, uint256 idx, uint256 requested) public pure {
        vm.assume(idx >= RAY && idx <= 1e29);
        vm.assume(scaledDebt >= 1 && scaledDebt <= 1e33);
        uint256 debt = scaledDebt.rayMul(idx);
        vm.assume(requested >= idx / RAY + 2 && requested < debt);
        uint256 newScaled = Math.mulDiv(debt - requested, WadRayMath.RAY, idx, Math.Rounding.Ceil);
        uint256 burned = debt - newScaled.rayMul(idx);
        assert(burned > 0);
    }

    // ───────────────────────────── FloatingMarket._premium (FloatingMarket.sol:215-227) ─────────────────────────────

    /// With nondecreasing indices the three valuations are ordered (no underflow at L225/L226) and the two
    /// components telescope exactly to the rise in totalDebt.
    function check_premium_telescopes(uint256 s, uint256 L0, uint256 U0, uint256 dL, uint256 dU) public pure {
        vm.assume(s <= 1e33);
        vm.assume(L0 >= RAY && L0 <= 1e29 && U0 >= RAY && U0 <= 1e29);
        vm.assume(dL <= 1e29 && dU <= 1e29);
        uint256 L1 = L0 + dL;
        uint256 U1 = U0 + dU;
        uint256 previousDebt = s.rayMul(L0.rayMul(U0)); // L222
        uint256 debtAfterLiquidity = s.rayMul(L1.rayMul(U0)); // L223
        uint256 currentDebt = s.rayMul(L1.rayMul(U1)); // L224
        assert(debtAfterLiquidity >= previousDebt);
        assert(currentDebt >= debtAfterLiquidity);
        uint256 liq = debtAfterLiquidity - previousDebt;
        uint256 uw = currentDebt - debtAfterLiquidity;
        assert(liq + uw == currentDebt - previousDebt);
    }

    // ───────────────────────────── Stablecoin haircut curve (Stablecoin.sol:236-294), 6-dec underlying ─────────────────────────────

    function _opposite(Math.Rounding r) internal pure returns (Math.Rounding) {
        return r == Math.Rounding.Ceil ? Math.Rounding.Floor : Math.Rounding.Ceil;
    }

    function _toAssets(uint256 shares, uint256 supply, uint256 badDebt, uint256 ud, Math.Rounding r)
        internal
        pure
        returns (uint256 assets)
    {
        uint256 value;
        if (badDebt == 0) {
            value = shares;
        } else {
            uint256 recognized = supply - badDebt;
            if (shares >= supply) {
                value = recognized;
            } else {
                uint256 remaining = supply - shares;
                uint256 anchor = supply * recognized;
                uint256 retained = Math.mulDiv(remaining, anchor, anchor + remaining * badDebt, _opposite(r));
                value = recognized > retained ? recognized - retained : 0;
            }
        }
        assets = Math.mulDiv(value, 10 ** ud, 1e18, r);
    }

    function _toShares(uint256 assets, uint256 supply, uint256 badDebt, uint256 ud, Math.Rounding r)
        internal
        pure
        returns (uint256 shares)
    {
        if (assets == 0) return 0;
        uint256 value = Math.mulDiv(assets, 1e18, 10 ** ud, r);
        if (badDebt == 0) return value;
        uint256 recognized = supply - badDebt;
        if (value >= recognized) return supply;
        uint256 retained = recognized - value;
        uint256 anchor = supply * recognized;
        uint256 remaining = Math.mulDiv(retained, anchor, anchor - retained * badDebt, _opposite(r));
        shares = supply > remaining ? supply - remaining : 0;
    }

    /// I36 at 6 decimals: the ceil-inverse of a floored payout never exceeds the shares redeemed, re-converting
    /// never pays more than the original quote (round trip cannot profit), and the round trip loses at most one
    /// asset-wei. Stated in ASSET units: the first run asserted `shares - back <= 1e12 + 1` and halmos refuted it
    /// (supply = badDebt + 2^35, shares = supply: the whole position is worth < 1 asset-wei, so assets = back = 0)
    /// — the same share-unit overreach the fuzz corrected for I36 (A.md, `1e12·(S/R)²`).
    function check_curve_inverse_6dec(uint256 supply, uint256 badDebt, uint256 shares) public pure {
        vm.assume(supply >= 1 && supply <= 1e30);
        vm.assume(badDebt >= 1 && badDebt < supply);
        vm.assume(shares >= 1 && shares <= supply);
        uint256 assets = _toAssets(shares, supply, badDebt, 6, Math.Rounding.Floor); // instantRedeem path
        uint256 back = _toShares(assets, supply, badDebt, 6, Math.Rounding.Ceil); // instantWithdraw path
        assert(back <= shares);
        uint256 assets2 = _toAssets(back, supply, badDebt, 6, Math.Rounding.Floor);
        assert(assets2 <= assets);
        assert(assets - assets2 <= 1); // within one asset-wei
    }

    /// Payout never exceeds par or backing (round trip cannot profit at any point of the curve).
    function check_curve_belowPar_6dec(uint256 supply, uint256 badDebt, uint256 shares) public pure {
        vm.assume(supply >= 1 && supply <= 1e30);
        vm.assume(badDebt >= 1 && badDebt <= supply);
        vm.assume(shares >= 1 && shares <= supply);
        uint256 assets = _toAssets(shares, supply, badDebt, 6, Math.Rounding.Floor);
        assert(assets * 1e12 <= shares);
        assert(assets * 1e12 <= supply - badDebt);
    }
}
