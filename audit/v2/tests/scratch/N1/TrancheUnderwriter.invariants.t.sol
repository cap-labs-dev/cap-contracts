// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// @dev The test contract is its own handler (it holds ADMIN + curator operator). Tranche `fund`
/// and `slash` are pranked from the market. Underwriter allocate/report come from the operator.
contract TrancheUnderwriterInvariants is CapDeployer {
    Tranche internal t;
    Underwriter internal u;
    address internal market;
    address[] internal actors;
    uint256[] internal reqIds;
    address[] internal reqCtrl;
    uint256 public tFunded;
    uint256 public tPaid;
    uint256 public tShort;
    uint256 public uFunded;
    uint256 public uPaid;
    uint256 public uShort;
    uint256 internal lastTs;

    function setUp() public {
        _deployCap();
        (address m, address t0,) = _createMarket("N1");
        market = m;
        t = Tranche(t0);
        u = _deployUnderwriter();
        u.addTranche(address(t)); // curator operator, opts the underwriter into the tranche
        actors.push(makeAddr("x0"));
        actors.push(makeAddr("x1"));
        actors.push(makeAddr("x2"));
        for (uint256 i; i < actors.length; ++i) {
            _admitDepositor(address(t), actors[i]);
            _admitDepositor(address(u), actors[i]);
            vm.startPrank(actors[i]);
            vault.setOperator(address(t), true);
            vault.setOperator(address(u), true);
            vm.stopPrank();
        }
        bytes4[] memory sel = new bytes4[](16);
        sel[0] = this.tDeposit.selector;
        sel[1] = this.tRedeem.selector;
        sel[2] = this.tRequestRedeem.selector;
        sel[3] = this.tClaimQueued.selector;
        sel[4] = this.tTransfer.selector;
        sel[5] = this.tOptIn.selector;
        sel[6] = this.tOptOut.selector;
        sel[7] = this.tFund.selector;
        sel[8] = this.tClaim.selector;
        sel[9] = this.tSlash.selector;
        sel[10] = this.uDeposit.selector;
        sel[11] = this.uRedeem.selector;
        sel[12] = this.uTransfer.selector;
        sel[13] = this.uOptToggle.selector;
        sel[14] = this.uAllocateReport.selector;
        sel[15] = this.warp.selector;
        targetSelector(FuzzSelector({ addr: address(this), selectors: sel }));
        targetContract(address(this));
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    // ---- tranche actions ----
    function tDeposit(uint256 s, uint256 amt) external {
        amt = bound(amt, 2_000, 1_000_000e18);
        address a = _a(s);
        _fundVault(a, amt);
        vm.prank(a);
        try t.deposit(amt, a) { } catch { }
    }

    function tRedeem(uint256 s, uint256 sh) external {
        address a = _a(s);
        uint256 m = t.maxRedeem(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(a);
        try t.redeem(sh, a, a) { } catch { }
    }

    function tRequestRedeem(uint256 s, uint256 sh) external {
        address a = _a(s);
        uint256 m = t.balanceOf(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(a);
        uint256 id = t.requestRedeem(sh, a, a);
        reqIds.push(id);
        reqCtrl.push(a);
    }

    function tClaimQueued(uint256 s, uint256 sh) external {
        if (reqIds.length == 0) return;
        uint256 i = s % reqIds.length;
        address c = reqCtrl[i];
        uint256 m = t.claimableRedeemRequest(reqIds[i], c);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(c);
        try t.redeem(reqIds[i], sh, c, c) { } catch { }
    }

    function tTransfer(uint256 sf, uint256 st, uint256 amt) external {
        address f = _a(sf);
        address to = _a(st);
        uint256 m = t.balanceOf(f);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        vm.prank(f);
        t.transfer(to, amt);
    }

    function tOptIn(uint256 s) external {
        vm.prank(_a(s));
        t.optIn();
    }

    function tOptOut(uint256 s) external {
        vm.prank(_a(s));
        t.optOut();
    }

    function tFund(uint256 amt) external {
        amt = bound(amt, 1, 10_000e18);
        vm.startPrank(market);
        stablecoin.mintCreditBacked(address(t), amt);
        t.fund(amt);
        vm.stopPrank();
        tFunded += amt;
    }

    function tClaim(uint256 s) external {
        address a = _a(s);
        uint256 c = t.claimable(a);
        uint256 b = stablecoin.balanceOf(a);
        vm.prank(a);
        t.claim(a);
        uint256 paid = stablecoin.balanceOf(a) - b;
        tPaid += paid;
        if (paid < c) tShort += c - paid;
    }

    function tSlash(uint256 v) external {
        uint256 cap = t.totalCapital();
        if (cap < 1e18) return;
        v = bound(v, 1, cap / 2);
        vm.prank(market);
        try t.slash(v, market) { } catch { }
    }

    // ---- underwriter actions ----
    function uDeposit(uint256 s, uint256 amt) external {
        amt = bound(amt, 2_000, 1_000_000e18);
        address a = _a(s);
        _fundVault(a, amt);
        vm.prank(a);
        try u.deposit(amt, a) { } catch { }
    }

    function uRedeem(uint256 s, uint256 sh) external {
        address a = _a(s);
        uint256 m = u.maxRedeem(a);
        if (m == 0) return;
        sh = bound(sh, 1, m);
        vm.prank(a);
        try u.redeem(sh, a, a) { } catch { }
    }

    function uTransfer(uint256 sf, uint256 st, uint256 amt) external {
        address f = _a(sf);
        address to = _a(st);
        uint256 m = u.balanceOf(f);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        vm.prank(f);
        u.transfer(to, amt);
    }

    function uOptToggle(uint256 s, bool inn) external {
        vm.prank(_a(s));
        if (inn) u.optIn();
        else u.optOut();
    }

    function uAllocateReport(uint256 amt, bool rep) external {
        if (rep) {
            uint256 c = t.claimable(address(u));
            uint256 b = stablecoin.balanceOf(address(u));
            u.report(address(t));
            uint256 paid = stablecoin.balanceOf(address(u)) - b;
            tPaid += paid;
            uFunded += paid;
            if (paid < c) tShort += c - paid;
            return;
        }
        uint256 free = vault.balanceOf(address(u), address(collateral));
        if (free < 2_000) return;
        amt = bound(amt, 2_000, free);
        try u.allocate(address(t), amt) { } catch { }
    }

    function uClaim(uint256 s) external {
        address a = _a(s);
        uint256 c = u.claimable(a);
        uint256 b = stablecoin.balanceOf(a);
        vm.prank(a);
        u.claim(a);
        uint256 paid = stablecoin.balanceOf(a) - b;
        uPaid += paid;
        if (paid < c) uShort += c - paid;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function _sumOpted(address v) internal view returns (uint256 sum) {
        Tranche p = Tranche(v);
        for (uint256 i; i < actors.length; ++i) {
            if (p.optedIn(actors[i])) sum += p.balanceOf(actors[i]);
        }
        if (v == address(t) && t.optedIn(address(u))) sum += t.balanceOf(address(u));
    }

    function _sumClaimable(address v) internal view returns (uint256 sum) {
        Tranche p = Tranche(v);
        for (uint256 i; i < actors.length; ++i) {
            sum += p.claimable(actors[i]);
        }
        if (v == address(t)) sum += t.claimable(address(u));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_tranche_I18_I19_I20() public view {
        assertEq(t.stakedSupply(), _sumOpted(address(t)), "T I18");
        assertFalse(t.optedIn(0x000000000000000000000000000000000000dEaD));
        uint256 rem = t.remaining();
        assertLe(tPaid + _sumClaimable(address(t)) + rem, tFunded + 64, "T I19");
        assertEq(tShort, 0, "T clamp bound");
        assertGe(stablecoin.balanceOf(address(t)), rem, "T pot backing");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_underwriter_I18_I19_I20() public view {
        assertEq(u.stakedSupply(), _sumOpted(address(u)), "U I18");
        uint256 rem = u.remaining();
        assertLe(uPaid + _sumClaimable(address(u)) + rem, uFunded + 64, "U I19");
        assertEq(uShort, 0, "U clamp bound");
        assertGe(stablecoin.balanceOf(address(u)), rem, "U pot backing");
    }
}
