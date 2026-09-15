// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Vault } from "../../../../contracts/cap/Vault.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../test/shared/CapRoles.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { MockOracle } from "../../../../test/shared/mocks/MockOracle.sol";
import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test, Vm } from "forge-std/Test.sol";

/// @dev ERC-7201 slot of cap.storage.ERC7540AsyncRedeem; struct order: requestId, redeemQueue,
/// settledQueue, queueIndex(mapping), queueNft.
library QueueSlots {
    bytes32 internal constant BASE = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    function redeemQueue(Vm vm, address v) internal view returns (uint256) {
        return uint256(vm.load(v, bytes32(uint256(BASE) + 1)));
    }

    function settledQueue(Vm vm, address v) internal view returns (uint256) {
        return uint256(vm.load(v, bytes32(uint256(BASE) + 2)));
    }

    function queueNft(Vm vm, address v) internal view returns (address) {
        return address(uint160(uint256(vm.load(v, bytes32(uint256(BASE) + 4)))));
    }
}

/// @notice Handler over the real Stablecoin: deposits, requests, partial claims, receipt
/// transfers, instant redeems, credit mint/burn and bad-debt recognition.
contract StablecoinQueueHandler is Test {
    using QueueSlots for Vm;

    Stablecoin public sc;
    MockERC20 public usd;
    address[] public actors;
    address public borrower;
    IERC1155 public nft;

    struct Req {
        uint256 id;
        address controller;
    }

    Req[] public reqs;

    constructor(Stablecoin _sc, MockERC20 _usd, address _borrower) {
        sc = _sc;
        usd = _usd;
        borrower = _borrower;
        nft = IERC1155(vm.queueNft(address(sc)));
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    function reqCount() external view returns (uint256) {
        return reqs.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1, 1_000e18);
        usd.mint(a, amount);
        vm.startPrank(a);
        usd.approve(address(sc), amount);
        sc.deposit(amount, a);
        vm.stopPrank();
    }

    function request(uint256 seed, uint256 frac, uint256 ctrlSeed) external {
        address a = _actor(seed);
        uint256 bal = sc.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(frac, 1, bal);
        address ctrl = _actor(ctrlSeed);
        vm.prank(a);
        uint256 id = sc.requestRedeem(shares, ctrl, a);
        reqs.push(Req(id, ctrl));
    }

    function claim(uint256 idx, uint256 frac) external {
        if (reqs.length == 0) return;
        Req memory r = reqs[idx % reqs.length];
        uint256 c = sc.claimableRedeemRequest(r.id, r.controller);
        if (c == 0) return;
        uint256 shares = bound(frac, 1, c);
        vm.prank(r.controller);
        sc.redeem(r.id, shares, r.controller, r.controller);
    }

    /// @dev split a receipt between two controllers
    function transferReceipt(uint256 idx, uint256 toSeed, uint256 frac) external {
        if (reqs.length == 0) return;
        Req memory r = reqs[idx % reqs.length];
        uint256 bal = nft.balanceOf(r.controller, r.id);
        if (bal == 0) return;
        address to = _actor(toSeed);
        if (to == r.controller) return;
        uint256 amt = bound(frac, 1, bal);
        vm.prank(r.controller);
        nft.safeTransferFrom(r.controller, to, r.id, amt, "");
        reqs.push(Req(r.id, to));
    }

    function instantRedeem(uint256 seed, uint256 frac) external {
        address a = _actor(seed);
        uint256 m = sc.maxRedeem(a);
        if (m == 0) return;
        uint256 shares = bound(frac, 1, m);
        vm.prank(a);
        sc.redeem(shares, a, a);
    }

    function mintCredit(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);
        sc.mintCreditBacked(borrower, amount);
    }

    function burnCredit(uint256 amount) external {
        uint256 max = sc.creditBackedSupply();
        uint256 bal = sc.balanceOf(borrower);
        if (max > bal) max = bal;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        sc.burnCreditBacked(borrower, amount);
    }

    function recognize(uint256 amount) external {
        uint256 max = sc.creditBackedSupply();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        sc.recognizeBadDebt(amount);
    }
}

contract B_StablecoinQueueInvariants is StdInvariant, CapDeployer {
    using QueueSlots for Vm;

    StablecoinQueueHandler internal h;

    function setUp() public {
        _deployCap();
        h = new StablecoinQueueHandler(stablecoin, cusdUnderlying, makeAddr("borrower"));
        accessManager.grantRole(CapRoles.MINTER, address(h), 0);
        targetContract(address(h));
    }

    /// I13: shares held by the vault == redemptionQueue == redeemQueue - settledQueue, and the
    /// ERC-1155 receipts outstanding sum to the same figure.
    function invariant_I13_queueConservation() public view {
        address v = address(stablecoin);
        uint256 rq = vm.redeemQueue(v);
        uint256 sq = vm.settledQueue(v);
        assertEq(stablecoin.redemptionQueue(), rq - sq, "redemptionQueue");
        assertEq(stablecoin.balanceOf(v), rq - sq, "vault share balance == queue");

        IERC1155 nft = IERC1155(vm.queueNft(v));
        uint256 sum;
        uint256 n = h.reqCount();
        // (id, controller) pairs may repeat after receipt transfers; dedupe by scanning
        for (uint256 i; i < n; ++i) {
            (uint256 id, address ctrl) = h.reqs(i);
            bool seen;
            for (uint256 j; j < i; ++j) {
                (uint256 id2, address c2) = h.reqs(j);
                if (id2 == id && c2 == ctrl) {
                    seen = true;
                    break;
                }
            }
            if (!seen) sum += nft.balanceOf(ctrl, id);
        }
        assertEq(sum, rq - sq, "sum of receipts == queue");
    }

    /// Sum over open requests of claimable never exceeds unlockedSupply (Stablecoin: HOLDS,
    /// because unlockedSupply only falls through claims and capped instant redemptions).
    function invariant_sumClaimable_le_unlocked() public view {
        uint256 n = h.reqCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            (uint256 id, address ctrl) = h.reqs(i);
            bool seen;
            for (uint256 j; j < i; ++j) {
                (uint256 id2, address c2) = h.reqs(j);
                if (id2 == id && c2 == ctrl) {
                    seen = true;
                    break;
                }
            }
            if (!seen) sum += stablecoin.claimableRedeemRequest(id, ctrl);
        }
        assertLe(sum, stablecoin.unlockedSupply(), "sum claimable <= unlocked");
    }

    /// I15 FIFO (positional): if any request with a higher id has claimable > 0 then every
    /// request with a lower id is fully claimable (pending == 0).
    function invariant_I15_fifo() public view {
        uint256 n = h.reqCount();
        for (uint256 i; i < n; ++i) {
            (uint256 idI, address cI) = h.reqs(i);
            if (stablecoin.claimableRedeemRequest(idI, cI) == 0) continue;
            for (uint256 j; j < n; ++j) {
                (uint256 idJ, address cJ) = h.reqs(j);
                if (idJ < idI) {
                    assertEq(stablecoin.pendingRedeemRequest(idJ, cJ), 0, "earlier request still pending");
                }
            }
        }
    }

    /// I1: reserve covers unlockedSupply (18-dec underlying, so no scaling).
    function invariant_I1_reserveCoversUnlocked() public view {
        assertGe(cusdUnderlying.balanceOf(address(stablecoin)), stablecoin.unlockedSupply(), "I1");
    }
}

/// @notice Handler over a real Tranche with a market: deposits, requests, claims, borrow, repay,
/// time and price moves. unlockedSupply moves exogenously here.
contract TrancheQueueHandler is Test {
    Tranche public t;
    FloatingMarket public market;
    Vault public vault;
    MockERC20 public coll;
    MockOracle public oracle;
    Stablecoin public sc;
    address public borrower;
    address[] public actors;

    struct Req {
        uint256 id;
        address controller;
    }

    Req[] public reqs;

    constructor(
        Tranche _t,
        FloatingMarket _m,
        Vault _v,
        MockERC20 _c,
        MockOracle _o,
        Stablecoin _sc,
        address _borrower,
        address[] memory _actors
    ) {
        t = _t;
        market = _m;
        vault = _v;
        coll = _c;
        oracle = _o;
        sc = _sc;
        borrower = _borrower;
        actors = _actors;
    }

    function reqCount() external view returns (uint256) {
        return reqs.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 2e3, 1_000e18);
        coll.mint(a, amount);
        vm.startPrank(a);
        coll.approve(address(vault), amount);
        vault.deposit(address(coll), amount, a);
        vault.setOperator(address(t), true);
        t.deposit(amount, a);
        vm.stopPrank();
    }

    function request(uint256 seed, uint256 frac) external {
        address a = _actor(seed);
        uint256 bal = t.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(frac, 1, bal);
        vm.prank(a);
        uint256 id = t.requestRedeem(shares, a, a);
        reqs.push(Req(id, a));
    }

    function claim(uint256 idx, uint256 frac) external {
        if (reqs.length == 0) return;
        Req memory r = reqs[idx % reqs.length];
        uint256 c = t.claimableRedeemRequest(r.id, r.controller);
        if (c == 0) return;
        uint256 shares = bound(frac, 1, c);
        vm.prank(r.controller);
        t.redeem(r.id, shares, r.controller, r.controller);
    }

    function borrow(uint256 frac) external {
        uint256 avail = market.availableCredit();
        if (avail < 1e18) return;
        uint256 amt = bound(frac, 1e18, avail);
        vm.prank(borrower);
        market.borrow(borrower, amt);
    }

    function repay(uint256 frac) external {
        uint256 debt = market.totalDebt();
        if (debt < 1e18) return;
        uint256 amt = bound(frac, 1e18, debt);
        sc.mintCreditBacked(borrower, amt); // handler holds MINTER
        vm.prank(borrower);
        market.repay(amt);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    function price(uint256 p) external {
        oracle.setPrice(address(coll), bound(p, 0.5e18, 2e18));
    }
}

contract B_TrancheQueueInvariants is StdInvariant, CapDeployer {
    TrancheQueueHandler internal h;
    Tranche internal senior;
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        (address m, address s,) = _createMarket("Market A");
        market = FloatingMarket(m);
        senior = Tranche(s);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(type(uint256).max);

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("tactor", i)));
            _admitDepositor(s, actors[i]);
        }
        h = new TrancheQueueHandler(senior, market, vault, collateral, oracle, stablecoin, defaultBorrower, actors);
        accessManager.grantRole(CapRoles.MINTER, address(h), 0);
        targetContract(address(h));
    }

    /// EXPECTED TO FAIL on current code (finding B-1): claimable can exceed unlockedSupply once a
    /// later request settled before an earlier one and the lock then tightened.
    function invariant_sumClaimable_le_unlocked() public view {
        uint256 n = h.reqCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            (uint256 id, address ctrl) = h.reqs(i);
            sum += senior.claimableRedeemRequest(id, ctrl);
        }
        assertLe(sum, senior.unlockedSupply(), "sum claimable <= unlocked (tranche)");
    }

    /// I13 for the tranche (holds).
    function invariant_I13_trancheQueueConservation() public view {
        assertEq(senior.balanceOf(address(senior)), senior.redemptionQueue(), "vault share balance == queue");
    }
}
