// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// Adversarial verification of MED-STALE-FEED-BRICKS.
///
/// Market: senior 1000 A, junior 1 B (0.1%). Debt 500. A repriced so health == 1.05 exactly.
/// lt 0.8, buffer 0.1, bonus 2%, targetHealth 1.25, underwriter rate 20% APR.
contract Verify_StaleFeedBricks is CapDeployer {
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    MockERC20 tokenB;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant P0 = 0.65525e18; // health 1.05 on debt 500
    uint256 constant P1 = 0.6e18; // health ~0.96 -> liquidatable
    uint256 constant P2 = 0.4587e18; // -30% from P0

    function setUp() public {
        _deployCap();
        tokenB = _newCollateral("Token B", "B", 18, 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(tokenB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.95e27;
        weights[1] = 0.05e27;
        (address m, address[] memory ts) = _createMarket("Multi", defaultMarketOwner, defaultBorrower, assets, weights);
        market = FloatingMarket(m);
        senior = Tranche(ts[0]);
        junior = Tranche(ts[1]);
        _setMarketSlopes(m);

        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), address(tokenB), bob, 1e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        oracle.setPrice(address(collateral), P0);
        _mintStable(defaultLiquidator, 10_000e18);
    }

    function _health() internal view returns (uint256) {
        return market.healthiness();
    }

    function _liquidateMax() internal returns (uint256 repaid, uint256 slashed) {
        vm.prank(defaultLiquidator);
        (repaid, slashed) = market.liquidate(defaultLiquidator, type(uint256).max);
    }

    function _report(string memory tag) internal {
        emit log_string(tag);
        emit log_named_decimal_uint("  healthiness (ray)", _health(), 27);
        emit log_named_decimal_uint("  totalDebt", market.totalDebt(), 18);
        emit log_named_decimal_uint("  senior.totalCapital (USD)", senior.totalCapital(), 18);
        emit log_named_decimal_uint("  senior.totalAssets (A units)", senior.totalAssets(), 18);
        emit log_named_decimal_uint("  unrecoverableDebt", market.unrecoverableDebt(), 18);
        emit log_named_decimal_uint("  stablecoin.badDebt", stablecoin.badDebt(), 18);
    }

    // ── (b) pure time delay at health 1.05, no price move ──────────────────────────────────

    function test_b1_24hOutageNoPriceMove_nothingWasLiquidatableAnyway() public {
        _report("t0");
        assertApproxEqRel(_health(), 1.05e27, 0.001e18, "setup health 1.05");
        uint256 debt0 = market.totalDebt();

        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 24 hours);

        // feed returns (or ADMIN re-points the source); nothing changed in the meantime
        oracle.setPrice(address(tokenB), 1e18);
        market.chargePremium();
        _report("t+24h, feed back");
        emit log_named_decimal_uint("  extra debt accrued over 24h", market.totalDebt() - debt0, 18);
        assertGe(_health(), 1e27, "still healthy: liquidation would not have been possible even without the outage");
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.liquidate(defaultLiquidator, 1e18);
    }

    // ── (b) crash during the outage: compare against the same path with a live feed ────────

    function test_b2_noOutage_crashPath_liquidationsKeepUnderwritersAboveWater() public {
        vm.warp(block.timestamp + 2 hours);
        oracle.setPrice(address(collateral), P1);
        _report("t+2h, A=0.60, live feeds");
        (uint256 r1, uint256 s1) = _liquidateMax();
        emit log_named_decimal_uint("  liq#1 repaid", r1, 18);
        emit log_named_decimal_uint("  liq#1 slashed (A units)", s1, 18);
        _report("after liq#1");

        vm.warp(block.timestamp + 22 hours);
        oracle.setPrice(address(collateral), P2);
        _report("t+24h, A=0.4587");
        (uint256 r2, uint256 s2) = _liquidateMax();
        emit log_named_decimal_uint("  liq#2 repaid", r2, 18);
        emit log_named_decimal_uint("  liq#2 slashed (A units)", s2, 18);
        _report("FINAL (no outage)");
        assertEq(market.unrecoverableDebt(), 0, "no bad debt on the live-feed path");
        assertGt(senior.totalCapital(), 0, "underwriters keep a residual on the live-feed path");
    }

    function test_b3_outage_crashPath_liquidationBlocked_thenWipeAndBadDebt() public {
        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        oracle.setPrice(address(collateral), P1);

        // liquidation is bricked while A is at 0.60 and the market is genuinely unhealthy
        vm.prank(defaultLiquidator);
        (bool ok,) = address(market).call(abi.encodeCall(market.liquidate, (defaultLiquidator, type(uint256).max)));
        assertFalse(ok, "liquidate must revert during the outage");
        (ok,) = address(market).call(abi.encodeCall(market.writeOff, ()));
        assertFalse(ok, "writeOff must revert during the outage");
        emit log_string("t+2h, A=0.60, B stale: liquidate REVERT, writeOff REVERT");

        vm.warp(block.timestamp + 22 hours);
        oracle.setPrice(address(collateral), P2);
        // feed returns
        oracle.setPrice(address(tokenB), 1e18);
        _report("t+24h, A=0.4587, feed back");
        (uint256 r, uint256 s) = _liquidateMax();
        emit log_named_decimal_uint("  liq repaid", r, 18);
        emit log_named_decimal_uint("  liq slashed (A units)", s, 18);
        _report("FINAL (outage)");
        uint256 unrec = market.unrecoverableDebt();
        emit log_named_decimal_uint("  AVOIDABLE bad debt vs live-feed path", unrec, 18);
        assertGt(unrec, 0, "outage path ends in unrecoverable debt");
    }

    // ── correction: direction of the redemption blockade ───────────────────────────────────

    function test_c1_seniorStale_juniorCanStillRedeem() public {
        oracle.setStaleness(address(collateral), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        (bool ok,) = address(senior).call(abi.encodeCall(senior.maxRedeem, (alice)));
        emit log_named_string("senior.maxRedeem (own feed stale)", ok ? "ok" : "REVERT");
        uint256 jr = junior.maxRedeem(bob);
        emit log_named_decimal_uint("junior.maxRedeem(bob) with senior feed stale", jr, 18);
        assertFalse(ok);
        // junior sits at the bottom of lockedValue's walk, so it never reads the senior's price
    }

    // ── escape hatches ─────────────────────────────────────────────────────────────────────

    function test_d1_setTranchesEscapeHatchRevertsWhenUnhealthy() public {
        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        oracle.setPrice(address(collateral), P1); // unhealthy on the senior alone

        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: address(senior), weight: 1e27 });
        (bool ok, bytes memory ret) = address(market).call(abi.encodeCall(market.setTranches, (only)));
        emit log_named_string("ADMIN setTranches([senior]) while unhealthy", ok ? "ok" : "REVERT");
        assertFalse(ok);
        assertEq(bytes4(ret), IBaseMarket.Unhealthy.selector, "reverts Unhealthy, not a role error");
    }

    function test_d2_setTranchesEscapeHatchWorksWhileHealthy_thenJuniorExitsFree() public {
        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: address(senior), weight: 1e27 });
        market.setTranches(only);
        emit log_string("ADMIN setTranches([senior]) while healthy: ok");
        // senior redemption no longer reverts (0 here only because at health 1.05 everything is locked)
        (bool ok,) = address(senior).call(abi.encodeCall(senior.maxRedeem, (alice)));
        assertTrue(ok, "senior.maxRedeem no longer reverts");
        oracle.setPrice(address(collateral), P1);
        (uint256 r,) = _liquidateMax();
        assertGt(r, 0, "liquidation works once the stale tranche is out of the waterfall");
    }

    function test_d3_rePostingTheFeedRestoresEverythingImmediately() public {
        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        oracle.setPrice(address(collateral), P1);
        // models ADMIN setSource/setBackup to a working adapter: one tx, no delay in the role table
        oracle.setPrice(address(tokenB), 1e18);
        (uint256 r,) = _liquidateMax();
        assertGt(r, 0);
        (bool ok,) = address(senior).call(abi.encodeCall(senior.maxRedeem, (alice)));
        assertTrue(ok, "senior.maxRedeem no longer reverts");
    }
}
