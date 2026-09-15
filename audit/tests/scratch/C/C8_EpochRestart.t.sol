// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-C: Registry restricts notifyPremium to the market "so nobody can restart the release
/// schedule by donating a wei and poking it". FloatingMarket.chargePremium() is public and does
/// exactly that on every call: fund() re-spreads locked()+dust over a fresh full period.
/// Quantifies how much of a lump arriving at t=0 is released after one nominal period when the
/// schedule is poked every 10 minutes.
contract C8_EpochRestart is CapDeployer {
    address alice = makeAddr("alice");

    function setUp() public {
        _deployCap();
    }

    function test_publicChargePremiumTurnsLinearReleaseIntoDecay() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, alice, 1000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        // a lump: 30 days of accrual charged at once
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 lump = b.tranche0.vested();
        emit log_named_uint("lump funded at t0 (cUSD)", lump);

        // control: nobody pokes -> fully released after 6h
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 6 hours);
        uint256 quiet = b.tranche0.claimable(alice);
        vm.revertToState(snap);

        // poked every 10 minutes (anyone can call chargePremium; every borrow/repay does too)
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
