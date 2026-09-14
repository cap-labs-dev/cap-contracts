// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../../../contracts/cap/Vault.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";

/// I37 handler-checkable statement:
///
///   book(uw)  := Vault.balanceOf(uw, asset) + uw.totalDebt()
///   live(uw)  := Vault.balanceOf(uw, asset) + sum_t Tranche(t).convertToAssets(balanceOf(uw) + queuedShares[t])
///
///   (I37a) book + (rounding gifts from third-party tranche flow, <= 1 wei each) >= live at every
///          step, absent ERC-6909 donations to a tranche;
///   (I37b) after `report(t)` for every t with debt[t] > 0 or balance > 0: book == live.
///
/// The handler exercises: underwriter deposit / instantRedeem (alice), allocate / deallocate /
/// deallocateAsync / finalize, market slash (pranked as the market), report, and direct tranche
/// deposits/redeems by a third party (which must not move the per-share price). Donations are
/// deliberately excluded (see C2_StaleMark.test_I37_donationIsTheOnlyStaleLowPath).
contract I37Handler is Test {
    Underwriter public uw;
    Tranche public t0;
    Tranche public t1;
    Vault public vault;
    MockERC20 public collateral;
    address public alice;
    address public carol;
    uint256[] public openRequests;
    /// ghost: every third-party deposit/redeem in a tranche can gift the remaining holders up to
    /// 1 wei of rounding (floor on the mover's side), which is the only way live can exceed book
    uint256 public thirdPartyOps;

    constructor(
        Vault _vault,
        MockERC20 _collateral,
        Underwriter _uw,
        Tranche _t0,
        Tranche _t1,
        address _alice,
        address _carol
    ) {
        vault = _vault;
        collateral = _collateral;
        uw = _uw;
        t0 = _t0;
        t1 = _t1;
        alice = _alice;
        carol = _carol;
    }

    function _fund(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(vault), amount);
        vault.deposit(address(collateral), amount, who);
        vm.stopPrank();
    }

    function _t(uint256 seed) internal view returns (Tranche) {
        return seed % 2 == 0 ? t0 : t1;
    }

    function depositUw(uint256 amount) external {
        amount = bound(amount, 1e18, 1_000e18);
        _fund(alice, amount);
        vm.startPrank(alice);
        uw.deposit(amount, alice);
        vm.stopPrank();
    }

    function redeemUw(uint256 shares) external {
        uint256 max = uw.maxInstantRedeem(alice);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(alice);
        uw.instantRedeem(shares, alice, alice);
    }

    function allocate(uint256 seed, uint256 amount) external {
        if (_t(seed).killed()) return;
        uint256 idle = vault.balanceOf(address(uw), address(collateral));
        if (idle < 2e3) return;
        amount = bound(amount, 2e3, idle);
        uw.allocate(address(_t(seed)), amount);
    }

    function deallocate(uint256 seed, uint256 shares) external {
        Tranche t = _t(seed);
        uint256 bal = t.balanceOf(address(uw));
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        uw.deallocate(address(t), shares);
    }

    function deallocateAsync(uint256 seed, uint256 shares) external {
        Tranche t = _t(seed);
        uint256 bal = t.balanceOf(address(uw));
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        uint256 id = uw.deallocateAsync(address(t), shares);
        openRequests.push(seed % 2 == 0 ? id * 2 : id * 2 + 1);
    }

    function finalize(uint256 pick) external {
        if (openRequests.length == 0) return;
        pick = pick % openRequests.length;
        uint256 enc = openRequests[pick];
        Tranche t = enc % 2 == 0 ? t0 : t1;
        uint256 id = enc / 2;
        uint256 claimable = t.claimableRedeemRequest(id, address(uw));
        uint256 recorded = uw.queuedRequest(address(t), id);
        if (claimable == 0 || recorded == 0) return;
        uint256 shares = claimable < recorded ? claimable : recorded;
        uw.finalizeDeallocateAsync(address(t), id, shares);
        if (uw.queuedRequest(address(t), id) == 0) {
            openRequests[pick] = openRequests[openRequests.length - 1];
            openRequests.pop();
        }
    }

    function slash(uint256 seed, uint256 value) external {
        Tranche t = _t(seed);
        uint256 total = t.totalAssets();
        if (total == 0) return;
        value = bound(value, 1, total); // price is 1.00 so value == assets
        vm.prank(t.market());
        t.slash(value, address(0xBEEF));
    }

    function report(uint256 seed) external {
        uw.report(address(_t(seed)));
    }

    function reportAll() external {
        uw.report(address(t0));
        uw.report(address(t1));
    }

    function thirdPartyDeposit(uint256 seed, uint256 amount) external {
        Tranche t = _t(seed);
        if (t.killed()) return;
        amount = bound(amount, 1e18, 500e18);
        _fund(carol, amount);
        vm.startPrank(carol);
        t.deposit(amount, carol);
        vm.stopPrank();
        thirdPartyOps++;
    }

    function thirdPartyRedeem(uint256 seed, uint256 shares) external {
        Tranche t = _t(seed);
        uint256 max = t.maxInstantRedeem(carol);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(carol);
        t.instantRedeem(shares, carol, carol);
        thirdPartyOps++;
    }
}

contract C7_I37Invariant is CapDeployer {
    Underwriter uw;
    MarketBundle b;
    I37Handler handler;
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        uw = _deployUnderwriter();
        _admitDepositor(b.tranche0Addr, address(uw));
        _admitDepositor(b.tranche1Addr, address(uw));
        _admitDepositor(b.tranche0Addr, carol);
        _admitDepositor(b.tranche1Addr, carol);
        uw.addTranche(b.tranche0Addr);
        uw.addTranche(b.tranche1Addr);
        _fundUnderwriter(address(uw), alice, 1_000e18);

        handler = new I37Handler(vault, collateral, uw, b.tranche0, b.tranche1, alice, carol);
        vm.prank(alice);
        vault.setOperator(address(uw), true);
        vm.startPrank(carol);
        vault.setOperator(b.tranche0Addr, true);
        vault.setOperator(b.tranche1Addr, true);
        vm.stopPrank();
        // the handler holds allocator + keeper powers (it is the honest operator here)
        accessManager.grantRole(_allocatorRole(address(uw)), address(handler), 0);
        accessManager.grantRole(3, address(handler), 0); // KEEPER
        targetContract(address(handler));
    }

    function _live() internal view returns (uint256 live) {
        live = vault.balanceOf(address(uw), address(collateral));
        live += b.tranche0.convertToAssets(b.tranche0.balanceOf(address(uw)) + uw.queuedShares(b.tranche0Addr));
        live += b.tranche1.convertToAssets(b.tranche1.balanceOf(address(uw)) + uw.queuedShares(b.tranche1Addr));
    }

    /// I37a. The first run without the tolerance failed by exactly 1 wei after a third-party
    /// deposit + redeem (floor rounding on the mover's side is a gift to remaining holders).
    function invariant_I37a_bookNeverBelowLive() public view {
        assertGe(uw.totalAssets() + handler.thirdPartyOps(), _live(), "I37a: book < live beyond rounding gifts");
    }

    /// I37b
    function invariant_I37b_equalAfterReportAll() public {
        handler.reportAll();
        assertEq(uw.totalAssets(), _live(), "I37b: book != live after report");
    }
}
