// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title StablecoinCurve6 — WS-A I36 on the REAL Stablecoin (proxy) with a 6-decimal underlying
/// The two reachable rounding paths are exercised through their public entry points:
///   convertToAssets(x)  == _convertToAssets(x, Floor)   (instantRedeem / redeem payout)
///   quoteWithdraw(a)    == _convertToShares(a, Ceil)    (instantWithdraw / withdraw burn, unlockedSupply cap)
/// State is set through the real paths: deposit (par mint), mintCreditBacked, recognizeBadDebtInReserve.
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/A forge test --match-path 'audit/v3/tests/scratch/A/StablecoinCurve6.t.sol' -vv --fuzz-runs 20000
import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev IRM stand-in: the stablecoin only calls updateLiquidityRate() on it.
contract NoopIRM {
    function updateLiquidityRate() external { }
}

contract StablecoinCurve6 is BaseTest {
    Stablecoin sc;
    MockERC20 usdc;
    uint256 constant SCALE = 1e12; // 18 - 6
    address whale = makeAddr("whale");

    function setUp() public {
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        NoopIRM irm = new NoopIRM();
        sc = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(0))
                )
            )
        );
        assertEq(sc.underlyingDecimals(), 6);
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = IStablecoin.mintCreditBacked.selector;
        sel[1] = IStablecoin.recognizeBadDebtInReserve.selector;
        _grantRoleForTarget(1, address(this), address(sc), sel);
    }

    /// supply shares held by `whale`, badDebt recognised in the reserve, USDC on hand = par of the deposit.
    function _state(uint256 supply, uint256 badDebt) internal {
        uint256 dep = supply / SCALE;
        if (dep > 0) {
            usdc.mint(whale, dep);
            vm.startPrank(whale);
            usdc.approve(address(sc), dep);
            sc.deposit(dep, whale);
            vm.stopPrank();
        }
        uint256 rem = supply - dep * SCALE;
        if (rem > 0) sc.mintCreditBacked(whale, rem); // sub-asset-wei remainder as credit so supply is exact
        if (badDebt > 0) sc.recognizeBadDebtInReserve(badDebt);
        assertEq(sc.totalSupply(), supply);
        assertEq(sc.badDebt(), badDebt);
    }

    // ───────────────────────── I36: inverse within one asset-wei, both directions, 6 dec ─────────────────────────

    function testFuzz_inverse_sharesToAssetsToShares(uint256 supply, uint256 badDebt, uint256 shares) public {
        supply = bound(supply, 1, 1e30);
        badDebt = bound(badDebt, 0, supply);
        shares = bound(shares, 1, supply);
        _state(supply, badDebt);
        uint256 assets = sc.convertToAssets(shares); // Floor
        uint256 back = sc.quoteWithdraw(assets); // Ceil inverse
        assertLe(back, shares, "ceil-inverse exceeds the shares that produced the quote");
        // In ASSET terms the pair is exact: the ceil-inverse of a floored payout fetches that payout.
        assertEq(sc.convertToAssets(back), assets, "requote differs");
        // In SHARE terms the gap is one asset-wei measured on the curve, whose slope is >= (R/S)^2 (convex,
        // minimal at x = 0), so gap <= 1e12 * (S/R)^2 + 1e12. The plan's "1e12 share-wei" is the par case
        // (fuzz CEX with 29% bad debt: gap = 1.96e12). See A.md.
        uint256 R = supply - badDebt;
        if (R > 0) {
            uint256 slopeBound = Math.mulDiv(SCALE, supply * supply, R * R) + SCALE;
            assertLe(shares - back, slopeBound, "inverse further than one asset-wei on the curve");
        }
    }

    function testFuzz_inverse_assetsToSharesToAssets(uint256 supply, uint256 badDebt, uint256 assets) public {
        supply = bound(supply, 1, 1e30);
        badDebt = bound(badDebt, 0, supply);
        uint256 backingAssets = (supply - badDebt) / SCALE;
        vm.assume(backingAssets > 0);
        assets = bound(assets, 1, backingAssets);
        _state(supply, badDebt);
        uint256 shares = sc.quoteWithdraw(assets); // instantWithdraw(assets) burns this
        uint256 paid = sc.convertToAssets(shares); // what the same shares fetch on the payout path
        assertGe(paid + 1, assets, "ceil-quoted shares fetch less than assets - 1");
        assertLe(paid, assets, "ceil-quoted shares fetch more than asked");
        assertLe(paid * SCALE, shares, "above par");
        assertLe(paid * SCALE, supply - badDebt, "above backing");
    }

    /// convertToAssets(quoteWithdraw(a)) <= a for any on-hand balance a, so the share cap that
    /// `unlockedSupply()` derives from the balance is always payable (no revert on the last claim).
    function testFuzz_quoteThenConvertNeverExceedsBalance(uint256 supply, uint256 badDebt, uint256 onHand) public {
        supply = bound(supply, 1, 1e30);
        badDebt = bound(badDebt, 0, supply);
        onHand = bound(onHand, 1, 1e24);
        _state(supply, badDebt);
        uint256 shares = sc.quoteWithdraw(onHand);
        assertLe(sc.convertToAssets(shares), onHand, "unlocked shares cost more than on-hand assets");
        // and the real cap: unlockedSupply() shares are payable from the real balance
        uint256 unlocked = sc.unlockedSupply();
        assertLe(sc.convertToAssets(unlocked), usdc.balanceOf(address(sc)), "unlockedSupply not payable");
    }

    // ───────────────────────── round trips never profit (deposit at par, exit on the curve) ─────────────────────────

    function testFuzz_depositInstantRedeem_neverProfits(uint256 supply, uint256 badDebt, uint256 dep) public {
        supply = bound(supply, 1e12, 1e30);
        badDebt = bound(badDebt, 0, supply);
        dep = bound(dep, 1, 1e15); // up to 1e9 USDC
        _state(supply, badDebt);
        address u = makeAddr("u");
        usdc.mint(u, dep);
        vm.startPrank(u);
        usdc.approve(address(sc), dep);
        uint256 shares = sc.deposit(dep, u);
        assertEq(shares, dep * SCALE, "par mint");
        uint256 maxShares = sc.maxInstantRedeem(u);
        vm.assume(maxShares > 0);
        uint256 got = sc.instantRedeem(maxShares, u, u);
        vm.stopPrank();
        assertLe(got, dep, "round trip profits");
        if (badDebt == 0 && maxShares == shares) assertEq(got, dep, "no haircut without bad debt");
        assertLe(sc.convertToAssets(sc.unlockedSupply()), usdc.balanceOf(address(sc)), "on-hand < unlocked");
    }

    function testFuzz_depositRequestClaim_neverProfits(uint256 supply, uint256 badDebt, uint256 dep, uint256 moreBad)
        public
    {
        supply = bound(supply, 1e12, 1e30);
        badDebt = bound(badDebt, 0, supply / 2);
        dep = bound(dep, 1, 1e15);
        _state(supply, badDebt);
        address u = makeAddr("u");
        usdc.mint(u, dep);
        vm.startPrank(u);
        usdc.approve(address(sc), dep);
        uint256 shares = sc.deposit(dep, u);
        uint256 id = sc.requestRedeem(shares, u, u);
        vm.stopPrank();
        // shortfall may grow while queued
        moreBad = bound(moreBad, 0, (sc.totalSupply() - sc.badDebt()) / 2);
        if (moreBad > 0) sc.recognizeBadDebtInReserve(moreBad);
        uint256 claimable = sc.claimableRedeemRequest(id, u);
        vm.assume(claimable > 0);
        uint256 before = usdc.balanceOf(u);
        vm.prank(u);
        sc.redeem(id, claimable, u, u);
        uint256 got = usdc.balanceOf(u) - before;
        assertLe(got, dep, "queued round trip profits");
        assertLe(sc.convertToAssets(sc.unlockedSupply()), usdc.balanceOf(address(sc)), "on-hand < unlocked");
    }

    // ───────────────────────── split-equivalence on the real exit path, across the shortfall domain ─────────────────────────

    function testFuzz_splitNeverBeatsSingle(uint256 supply, uint256 badDebt, uint256 x, uint256 cut) public {
        supply = bound(supply, 2e12, 1e30);
        badDebt = bound(badDebt, 1, supply - 1);
        _state(supply, badDebt);
        uint256 unlocked = sc.unlockedSupply();
        vm.assume(unlocked >= 2);
        x = bound(x, 2, unlocked);
        cut = bound(cut, 1, x - 1);
        uint256 single = sc.convertToAssets(x);
        vm.startPrank(whale);
        uint256 a1 = sc.instantRedeem(cut, whale, whale); // burns, pays, retires haircut via _onWithdraw
        uint256 a2 = sc.instantRedeem(x - cut, whale, whale);
        vm.stopPrank();
        assertLe(a1 + a2, single + 1, "split beats single by more than 1 asset-wei");
    }

    // ───────────────────────── _onWithdraw: reduction never exceeds badDebt; backing falls by exactly what was paid ─────────────────────────

    function testFuzz_onWithdrawAccounting(uint256 supply, uint256 badDebt, uint256 x) public {
        supply = bound(supply, 1e12, 1e30);
        badDebt = bound(badDebt, 1, supply);
        _state(supply, badDebt);
        uint256 unlocked = sc.unlockedSupply();
        vm.assume(unlocked > 0);
        x = bound(x, 1, unlocked);
        uint256 R0 = sc.backing();
        vm.prank(whale);
        uint256 got = sc.instantRedeem(x, whale, whale);
        uint256 R1 = sc.backing();
        assertLe(got * SCALE, x, "paid more than par");
        assertGe(R0 - R1, got * SCALE, "backing fell by less than the assets paid (phantom backing)");
        assertLe(R0 - R1, x, "backing fell by more than the shares burned");
        // reduction = min(badDebt, x - floor(paid)); the floor adds < 1e12 share-wei of dust to the exact
        // haircut, so the cap at L324 binds only when the exact haircut is within one asset-wei of ALL
        // remaining bad debt (near-full exit, or sub-asset-wei bad debt). Then badDebt hits 0 and the dust
        // stays on hand as unrecognised reserve (fuzz CEX: 7.3e10 share-wei = 7e-8 USDC). Harmless.
        assertLt(R0 - R1 - got * SCALE, SCALE, "backing fell by more than paid + one asset-wei");
        if (R0 - R1 != got * SCALE) assertEq(sc.badDebt(), 0, "cap bound without clearing bad debt");
        else assertEq(badDebt - sc.badDebt(), x - got * SCALE, "reduction == haircut taken");
        assertLe(sc.convertToAssets(sc.unlockedSupply()), usdc.balanceOf(address(sc)), "on-hand < unlocked");
    }

    // ───────────────────────── worked example for A.md ─────────────────────────

    function test_workedExample() public {
        // 1,000,000 cUSD supply, 100,000 bad debt => backing 900,000; USDC (6 dec)
        _state(1_000_000e18, 100_000e18);
        emit log_named_uint("payout for 10,000 cUSD (USDC 6d)", sc.convertToAssets(10_000e18));
        emit log_named_uint("payout for 500,000 cUSD", sc.convertToAssets(500_000e18));
        emit log_named_uint("payout for 1,000,000 cUSD", sc.convertToAssets(1_000_000e18));
        emit log_named_uint("shares to withdraw 8,100 USDC (ceil)", sc.quoteWithdraw(8_100e6));
        emit log_named_uint("shares to withdraw 1 USDC-wei (ceil)", sc.quoteWithdraw(1));
        emit log_named_uint("payout for 1e12 share-wei (1 USDC-wei at par)", sc.convertToAssets(1e12));
        emit log_named_uint("payout for 1.24e12 share-wei", sc.convertToAssets(124e10));
        emit log_named_uint("payout for 1.2346e12 share-wei", sc.convertToAssets(12346e8));
        uint256 back = sc.quoteWithdraw(sc.convertToAssets(12346e8));
        emit log_named_uint("ceil-inverse of that payout (share-wei)", back);
    }
}
