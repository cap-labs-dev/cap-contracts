// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../test/shared/mocks/MockIRM.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Handler over a standalone Stablecoin (PremiumVesting over itself) + a Wrapper.
contract StablecoinHandler is Test {
    Stablecoin public s;
    Wrapper public w;
    MockERC20 public usdc;
    address[] public actors;
    uint256[] public reqIds;
    address[] public reqCtrl;

    // ghosts
    uint256 public sumFunded; // shares put into the pot via fund/fundCreditBacked
    uint256 public sumPaid; // shares paid out by claim
    uint256 public donated; // raw transfers to address(s)
    uint256 public clampShortfall; // Σ (settled entitlement - actually paid)
    uint256 public claimCalls;
    uint256 public queuedBurnReverts;

    constructor(Stablecoin _s, Wrapper _w, MockERC20 _usdc) {
        s = _s;
        w = _w;
        usdc = _usdc;
        actors.push(makeAddr("a0"));
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            usdc.approve(address(s), type(uint256).max);
            vm.prank(actors[i]);
            s.approve(address(w), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _a(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e18);
        address a = _a(seed);
        usdc.mint(a, amt);
        vm.prank(a);
        s.deposit(amt, a);
    }

    function mintCredit(uint256 seed, uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e18);
        s.mintCreditBacked(_a(seed), amt);
    }

    function burnCredit(uint256 seed, uint256 amt) external {
        address a = _a(seed);
        uint256 m = s.balanceOf(a) < s.creditBackedSupply() ? s.balanceOf(a) : s.creditBackedSupply();
        if (m == 0) return;
        amt = bound(amt, 1, m);
        s.burnCreditBacked(a, amt);
    }

    function redeemInstant(uint256 seed, uint256 sh) external {
        address a = _a(seed);
        uint256 m = s.maxRedeem(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(a);
        s.redeem(sh, a, a);
    }

    function requestRedeem(uint256 seed, uint256 sh) external {
        address a = _a(seed);
        uint256 m = s.balanceOf(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(a);
        uint256 id = s.requestRedeem(sh, a, a);
        reqIds.push(id);
        reqCtrl.push(a);
    }

    function claimQueued(uint256 seed, uint256 sh) external {
        if (reqIds.length == 0) return;
        uint256 i = seed % reqIds.length;
        address c = reqCtrl[i];
        uint256 m = s.claimableRedeemRequest(reqIds[i], c);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(c);
        try s.redeem(reqIds[i], sh, c, c) { }
            catch {
            queuedBurnReverts++;
        }
    }

    function transfer(uint256 sf, uint256 st, uint256 amt) external {
        address f = _a(sf);
        address t = _a(st);
        uint256 m = s.balanceOf(f);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        vm.prank(f);
        s.transfer(t, amt);
    }

    function donateToVault(uint256 sf, uint256 amt) external {
        address f = _a(sf);
        uint256 m = s.balanceOf(f);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        vm.prank(f);
        s.transfer(address(s), amt);
        donated += amt;
    }

    function optIn(uint256 seed) external {
        vm.prank(_a(seed));
        s.optIn();
    }

    function optOut(uint256 seed) external {
        vm.prank(_a(seed));
        s.optOut();
    }

    function fundPublic(uint256 seed, uint256 amt) external {
        amt = bound(amt, 1, 100_000e18);
        address a = _a(seed);
        usdc.mint(a, amt);
        uint256 before = s.balanceOf(address(s));
        vm.prank(a);
        s.fund(amt);
        sumFunded += s.balanceOf(address(s)) - before;
    }

    function fundCredit(uint256 amt) external {
        amt = bound(amt, 1, 100_000e18);
        s.fundCreditBacked(amt);
        sumFunded += amt;
    }

    function claim(uint256 seed) external {
        address a = _a(seed);
        uint256 c = s.claimable(a);
        uint256 before = s.balanceOf(a);
        vm.prank(a);
        s.claim(a);
        uint256 paid = s.balanceOf(a) - before;
        sumPaid += paid;
        claimCalls++;
        if (paid < c) clampShortfall += c - paid;
    }

    function recognizeBadDebt(uint256 amt) external {
        uint256 m = s.creditBackedSupply();
        if (m == 0) return;
        amt = bound(amt, 1, m);
        s.recognizeBadDebt(amt);
    }

    function coverBadDebt(uint256 seed, uint256 amt) external {
        address a = _a(seed);
        if (s.badDebt() == 0 || s.balanceOf(a) == 0) return;
        amt = bound(amt, 1, s.balanceOf(a));
        vm.prank(a);
        s.coverBadDebt(amt);
    }

    function wrapperDeposit(uint256 seed, uint256 amt) external {
        address a = _a(seed);
        uint256 m = s.balanceOf(a);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        uint256 c = s.claimable(address(w));
        uint256 before = s.balanceOf(address(w));
        vm.prank(a);
        w.deposit(amt, a);
        uint256 paid = s.balanceOf(address(w)) - before - amt;
        sumPaid += paid;
        if (paid < c) clampShortfall += c - paid;
    }

    function wrapperRedeem(uint256 seed, uint256 sh) external {
        address a = _a(seed);
        uint256 m = w.balanceOf(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        uint256 c = s.claimable(address(w));
        uint256 before = s.balanceOf(address(w));
        vm.prank(a);
        uint256 out = w.redeem(sh, a, a);
        uint256 paid = s.balanceOf(address(w)) + out - before;
        sumPaid += paid;
        if (paid < c) clampShortfall += c - paid;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }
}

contract StablecoinInvariants is BaseTest {
    Stablecoin internal s;
    Wrapper internal w;
    MockERC20 internal usdc;
    StablecoinHandler internal h;
    uint256 internal lastPrice = 1e18;

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
        h = new StablecoinHandler(s, w, usdc);
        accessManager.grantRole(0, address(h), 0); // handler may call restricted fns
        targetContract(address(h));
    }

    function _sumOptedIn() internal view returns (uint256 sum) {
        for (uint256 i; i < h.actorCount(); ++i) {
            address a = h.actors(i);
            if (s.optedIn(a)) sum += s.balanceOf(a);
        }
        if (s.optedIn(address(w))) sum += s.balanceOf(address(w));
    }

    function _sumClaimable() internal view returns (uint256 sum) {
        for (uint256 i; i < h.actorCount(); ++i) {
            sum += s.claimable(h.actors(i));
        }
        sum += s.claimable(address(w));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_I18_stakedEqualsSumOptedIn() public view {
        assertEq(s.stakedSupply(), _sumOptedIn(), "I18");
        assertFalse(s.optedIn(address(s)));
        assertFalse(s.optedIn(0x000000000000000000000000000000000000dEaD));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_I13_potPlusQueueExact() public view {
        // every share at address(s) is pot (funded - paid), donation, or queue: exact accounting
        assertEq(s.balanceOf(address(s)), h.sumFunded() + h.donated() - h.sumPaid() + s.redemptionQueue(), "pot+queue");
        assertGe(s.balanceOf(address(s)), s.redemptionQueue(), "I13'");
        assertGe(h.sumFunded() + h.donated(), h.sumPaid(), "pot overdrawn into queue");
        assertEq(h.queuedBurnReverts(), 0, "queued burn reverted");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_I19_I20_conservation() public view {
        uint256 rem = s.remaining(); // reverts on underflow -> I20
        assertLe(s.vested(), rem + s.vested(), "vested<=remainder");
        assertLe(h.sumPaid() + _sumClaimable() + rem, h.sumFunded() + 64, "I19 conservation (+64 wei dust)");
        assertLe(h.sumFunded() - h.sumPaid() + h.donated(), h.sumFunded() + h.donated(), "paid<=funded");
        assertEq(h.clampShortfall(), 0, "claim clamp bound: entitlement forfeited");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_I21_wrapperPriceMonotone() public {
        if (w.totalSupply() == 0) {
            lastPrice = 1e18;
            return;
        }
        uint256 p = w.previewRedeem(1e18);
        assertGe(p + 2, lastPrice, "I21 wrapper share price fell");
        lastPrice = p;
    }
}
