// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// R2 (L-13). Round-1 premise (linear 6h epoch restarted by every fund) is gone: the vest is
/// now `1 - r^t` with a fixed 12h time constant and no epoch. Positive test: the release curve
/// of a single pot must be identical whether or not the vesting is poked every 10 minutes.
contract L13_EpochRestart is CapDeployer {
    address alice = makeAddr("alice");
    address poker = makeAddr("poker");
    MarketBundle b;
    uint256 lump;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        vm.warp(block.timestamp + 30 days);
        // fund the pot once, then clear all debt so later pokes cannot fund anything new
        _mintStable(defaultBorrower, 100e18);
        vm.prank(defaultBorrower);
        b.market.repay(type(uint256).max);
        assertEq(b.market.totalDebt(), 0, "debt cleared");
        lump = b.tranche0.remaining();
        emit log_named_uint("lump funded at t0 (cUSD)", lump);
    }

    function _poke() internal {
        b.market.chargePremium(); // public poke; zero debt so funds nothing
        vm.prank(poker);
        b.tranche0.optIn(); // runs updatePremium -> _accrue on the tranche itself
    }

    function _curve(bool poke) internal returns (uint256[4] memory c) {
        uint256[4] memory ts = [uint256(1 hours), 6 hours, 12 hours, 24 hours];
        uint256 t0 = block.timestamp;
        uint256 k;
        uint256 t = t0;
        while (t < t0 + 24 hours) {
            uint256 next = poke ? t + 10 minutes : t0 + ts[k];
            if (next > t0 + ts[k]) next = t0 + ts[k];
            t = next;
            vm.warp(t);
            if (poke) _poke();
            if (t == t0 + ts[k]) {
                c[k] = b.tranche0.claimable(alice);
                k++;
            }
        }
    }

    function test_L13_pokedAndUnpokedReleaseCurvesMatch() public {
        uint256 snap = vm.snapshotState();
        uint256[4] memory quiet = _curve(false);
        vm.revertToState(snap);
        uint256[4] memory poked = _curve(true);
        string[4] memory lbl = ["1h", "6h", "12h", "24h"];
        for (uint256 i; i < 4; ++i) {
            emit log_named_uint(string.concat("claimable quiet  @", lbl[i]), quiet[i]);
            emit log_named_uint(string.concat("claimable poked  @", lbl[i]), poked[i]);
            emit log_named_uint(string.concat("released bps     @", lbl[i]), quiet[i] * 10_000 / lump);
            assertApproxEqRel(poked[i], quiet[i], 1e12, "poking must not change the release curve");
        }
        // sanity of exponential shape: 12h ~ 63.2%, 24h ~ 86.5%
        assertApproxEqRel(quiet[2] * 1e18 / lump, 0.632e18, 0.01e18, "12h ~ 1-1/e");
        assertApproxEqRel(quiet[3] * 1e18 / lump, 0.865e18, 0.01e18, "24h ~ 1-1/e^2");
    }
}

/// Straight port of C8_EpochRestart with the same assertion. Debt is left outstanding as in
/// round 1, so pokes still fund new premium; the assertion (poked >= quiet - 1e15) is kept.
contract L13_C8_EpochRestartPort is CapDeployer {
    address alice = makeAddr("alice");

    function setUp() public {
        _deployCap();
    }

    function test_publicChargePremiumTurnsLinearReleaseIntoDecay() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 lump = b.tranche0.remaining();
        emit log_named_uint("lump funded at t0 (cUSD)", lump);

        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 6 hours);
        uint256 quiet = b.tranche0.claimable(alice);
        vm.revertToState(snap);

        for (uint256 i; i < 36; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            b.market.chargePremium();
        }
        uint256 poked = b.tranche0.claimable(alice);
        emit log_named_uint("claimable after 6h, unpoked", quiet);
        emit log_named_uint("claimable after 6h, poked every 10 min", poked);
        emit log_named_uint("still locked, poked (bps of lump)", (lump - poked) * 10_000 / lump);
        assertGe(poked + 1e15, quiet, "vesting is advertised as linear over the period");
    }
}
