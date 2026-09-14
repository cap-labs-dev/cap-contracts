// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title VestingAndIrmDust — WS-A: PremiumVesting floor dust (stranded, farmable?) and IRM average bounds
/// Run: FOUNDRY_TEST=audit/v3/tests/scratch/A forge test --match-path 'audit/v3/tests/scratch/A/VestingAndIrmDust.t.sol' -vv --fuzz-runs 20000
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract VestingAndIrmDust is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    Tranche tranche0;
    address supplier = makeAddr("supplier");

    function setUp() public {
        _deployCap();
        (address m, address t0,) = _createMarket("vm");
        market = FloatingMarket(m);
        tranche0 = Tranche(t0);
    }

    // ───────────────────────── PremiumVesting: dust stranded by the floors ─────────────────────────

    /// Poke the pot every 12 s. `_vested` = floor(remainder * w / RAY) with w(12s) ~ 2.78e-4 ray, so any
    /// remainder below ~3600 wei never vests while being poked; it is not lost (a longer gap vests it)
    /// and no account can claim it. The per-share floor additionally leaves < supply/RAY wei per accrual
    /// in the contract balance, unclaimable by anyone.
    function test_vestingDustStrandedUnderContinuousPoking() public {
        _fundTranche(address(tranche0), supplier, 1_000e18);
        // fund a 1e6-wei pot (dust-scale) and a 1e21-wei pot (real-scale) in turn
        _mintStable(address(this), 1e21);
        stablecoin.approve(address(tranche0), 1e21);
        // route through fund(): tranche.fund is MARKET-restricted; the deployer holds MARKET
        stablecoin.transfer(address(tranche0), 1e21);
        tranche0.fund(1e21);
        uint256 rem0 = tranche0.remaining();
        for (uint256 i; i < 2000; ++i) {
            vm.warp(block.timestamp + 12);
            tranche0.optIn(); // any accruing call; no-op for a non-holder but runs updatePremium
        }
        uint256 rem1 = tranche0.remaining();
        emit log_named_uint("pot", 1e21);
        emit log_named_uint("remaining after 2000 x 12s pokes", rem1);
        emit log_named_uint("expected continuous remaining (1e21 * e^-(24000/43200))", 1e21 * 573753 / 1_000_000);
        // now let it sit 40 days: rayPow(retention, elapsed) reaches 0 after 31.4 days => weight = RAY => all vests
        vm.warp(block.timestamp + 40 days);
        tranche0.optIn();
        emit log_named_uint("remaining after a further 40 days", tranche0.remaining());
        assertEq(tranche0.remaining(), 0, "a long gap vests everything, nothing is permanently stranded in remainder");
        // what is unclaimable: pot minus what the single staker can claim
        vm.prank(supplier);
        uint256 claimed = tranche0.claim(supplier);
        emit log_named_uint("claimed by the only staker", claimed);
        emit log_named_uint(
            "stranded in contract balance (per-share floor dust)", stablecoin.balanceOf(address(tranche0))
        );
        assertLe(
            stablecoin.balanceOf(address(tranche0)), 2000 + 1, "per-share floor strands more than 1 wei per accrual"
        );
        assertGe(claimed + stablecoin.balanceOf(address(tranche0)), 1e21 - 1, "conservation");
        rem0; // silence
    }

    /// Farmability: an opted-in account that splits its balance across k accounts, or that claims every
    /// second, can only lose to the floors — the sum of many small floors is <= the single floor.
    function testFuzz_vestingSplitNeverGains(uint256 pot, uint256 balA, uint256 balB, uint32 dt) public {
        pot = bound(pot, 1, 1e24);
        balA = bound(balA, 1e3 + 1, 1e24);
        balB = bound(balB, 1e3 + 1, 1e24);
        dt = uint32(bound(dt, 1, 30 days));
        address a = makeAddr("a");
        address b = makeAddr("b");
        // single holder with balA + balB vs two holders
        uint256 snap = vm.snapshotState();
        _fundTranche(address(tranche0), a, balA + balB);
        _fundPot(pot);
        vm.warp(block.timestamp + dt);
        vm.prank(a);
        uint256 single = tranche0.claim(a);
        vm.revertToState(snap);
        _fundTranche(address(tranche0), a, balA);
        _fundTranche(address(tranche0), b, balB);
        _fundPot(pot);
        vm.warp(block.timestamp + dt);
        vm.prank(a);
        uint256 ca = tranche0.claim(a);
        vm.prank(b);
        uint256 cb = tranche0.claim(b);
        assertLe(ca + cb, single + 1, "splitting a balance across accounts farms the floors");
    }

    function _fundPot(uint256 pot) internal {
        _mintStable(address(this), pot);
        stablecoin.transfer(address(tranche0), pot);
        tranche0.fund(pot);
    }

    // ───────────────────────── IRM: averaged credit never exceeds averaged supply (kink == 1e27 safety) ─────────────────────────

    // InterestRateModel.sol:279-283
    function _carry(uint256 average, uint256 observed, uint256 weight) internal pure returns (uint256) {
        return observed > average
            ? average + (observed - average).rayMul(weight)
            : average - (average - observed).rayMul(weight);
    }

    /// If avgCredit <= avgSupply and obsCredit <= obsSupply then the carried pair keeps credit <= supply,
    /// so `_ratio` <= 1e27 and `_nextLiquidityRate` never divides by `1e27 - kink == 0` when kink == 1e27.
    function testFuzz_carryPreservesOrder(uint256 c, uint256 s, uint256 oc, uint256 os, uint256 w) public pure {
        s = bound(s, 0, 1e33);
        c = bound(c, 0, s);
        os = bound(os, 0, 1e33);
        oc = bound(oc, 0, os);
        w = bound(w, 0, 1e27);
        uint256 c1 = _carry(c, oc, w);
        uint256 s1 = _carry(s, os, w);
        assertLe(c1, s1, "carried credit exceeds carried supply");
    }

    /// The live check on the deployed IRM with kink pinned at 1e27: rates never revert across random
    /// mint/deposit/warp sequences.
    function testFuzz_kinkAtOne_noRevert(uint256 seed) public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 1e27 })
        );
        for (uint256 i; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + r % 1 days);
            if (r % 2 == 0) _mintStable(address(this), (r >> 8) % 1e21 + 1);
            else _depositStable(address(this), (r >> 8) % 1e21 + 1);
            irm.fixedRatesAfterMint(address(market), 0.5e27, (r >> 64) % 1e21);
            irm.averageUtilizationAfterMint(0);
        }
    }
}
