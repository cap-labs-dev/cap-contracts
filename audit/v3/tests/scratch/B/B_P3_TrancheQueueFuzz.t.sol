// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface IHarness {
    function harnessSetPrice(uint256 p) external;
    function harnessMintStable(address to, uint256 amount) external;
}

/// @notice P3 handler: request / claim4 / claim3 / borrow / repay / liquidate / movePrice / warp on a
/// two-tranche floating market. Ghosts record any claim that exceeds the live unlockedSupply at the
/// moment of the claim, any redeem(maxRedeem) that reverts (I26), and any claim that takes a healthy
/// market to healthiness < 1e27 (the H-2 statement).
contract TrancheQueueHandler is Test {
    Tranche public senior;
    Tranche public junior;
    FloatingMarket public market;
    IHarness internal harness;
    address internal borrower;
    address internal liquidator;
    address[] public actors;
    uint256[] public ids;

    uint256 public overclaims;
    uint256 public i26Violations;
    uint256 public healthFlips;
    uint256 public claims;
    uint256 public paidShares;
    uint256 public sumUnlockedObserved;
    uint256 public calls;
    string public lastI26Reason;

    constructor(
        Tranche _senior,
        Tranche _junior,
        FloatingMarket _market,
        IHarness _harness,
        address _borrower,
        address _liquidator,
        address[] memory _actors
    ) {
        senior = _senior;
        junior = _junior;
        market = _market;
        harness = _harness;
        borrower = _borrower;
        liquidator = _liquidator;
        actors = _actors;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _ownedId(address c, uint256 seed) internal view returns (uint256 id) {
        uint256 n = ids.length;
        if (n == 0) return 0;
        seed = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 cand = ids[(seed + k) % n];
            if (senior.controllerOf(cand) == c) return cand;
        }
    }

    // ── ops ───────────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        calls++;
        if (senior.killed()) return;
        address a = _actor(actorSeed);
        amount = bound(amount, 1e15, 200e18);
        vm.prank(a);
        try senior.deposit(amount, a) { } catch { }
    }

    function request(uint256 actorSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 bal = senior.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bal * bound(frac, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(a);
        uint256 id = senior.requestRedeem(shares, a, a);
        ids.push(id);
    }

    function transferRequest(uint256 actorSeed, uint256 idSeed, uint256 toSeed) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 id = _ownedId(a, idSeed);
        if (id == 0) return;
        vm.prank(a);
        senior.transferRequest(id, _actor(toSeed));
    }

    function claim4(uint256 actorSeed, uint256 idSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 id = _ownedId(a, idSeed);
        if (id == 0) return;
        uint256 claimable = senior.claimableRedeemRequest(id, a);
        if (claimable == 0) return;
        uint256 shares = claimable * bound(frac, 1, 10_000) / 10_000;
        if (shares == 0) return;
        _claimAndCheck(a, id, shares, true);
    }

    function claim3(uint256 actorSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 max = senior.maxRedeem(a);
        if (max == 0) return;
        uint256 f = bound(frac, 1, 10_000);
        uint256 shares = max * f / 10_000;
        if (shares == 0) return;
        _claimAndCheck(a, 0, shares, f == 10_000);
    }

    function _claimAndCheck(address a, uint256 id, uint256 shares, bool mustSucceed) internal {
        uint256 unlockedBefore = senior.unlockedSupply();
        uint256 healthBefore = market.healthiness();
        bool ok;
        bytes memory err;
        vm.prank(a);
        if (id == 0) {
            try senior.redeem(shares, a, a) {
                ok = true;
            }
                catch (bytes memory e) {
                err = e;
            }
        } else {
            try senior.redeem(id, shares, a, a) {
                ok = true;
            }
                catch (bytes memory e) {
                err = e;
            }
        }
        if (!ok) {
            if (mustSucceed) {
                i26Violations++;
                lastI26Reason = vm.toString(err);
            }
            return;
        }
        claims++;
        paidShares += shares;
        sumUnlockedObserved += unlockedBefore;
        if (shares > unlockedBefore) overclaims++;
        if (healthBefore >= 1e27 && market.healthiness() < 1e27) healthFlips++;
    }

    function borrow(uint256 amount) external {
        calls++;
        uint256 credit = market.availableCredit();
        if (credit < 1e15) return;
        amount = bound(amount, 1e15, credit);
        vm.prank(borrower);
        try market.borrow(borrower, amount) { } catch { }
    }

    function repay(uint256 frac) external {
        calls++;
        uint256 debt = market.totalDebt();
        if (debt == 0) return;
        uint256 amount = debt * bound(frac, 1, 10_000) / 10_000;
        if (amount == 0) return;
        harness.harnessMintStable(borrower, amount);
        vm.prank(borrower);
        try market.repay(amount) { } catch { }
    }

    function liquidate(uint256 frac) external {
        calls++;
        if (market.healthiness() >= 1e27) return;
        uint256 max = market.maxLiquidatable();
        if (max == 0) return;
        uint256 amount = max * bound(frac, 1, 10_000) / 10_000;
        if (amount == 0) return;
        harness.harnessMintStable(liquidator, amount);
        vm.prank(liquidator);
        try market.liquidate(liquidator, amount) { } catch { }
    }

    function movePrice(uint256 seed) external {
        calls++;
        uint256 p = bound(seed, 0.2e18, 5e18);
        p -= p % 1e10;
        harness.harnessSetPrice(p);
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 1 days));
    }
}

/// forge-config: default.invariant.runs = 80
/// forge-config: default.invariant.depth = 300
/// forge-config: default.invariant.fail-on-revert = true
contract B_P3_TrancheQueueFuzz is CapDeployer {
    TrancheQueueHandler internal handler;
    Tranche internal senior;
    Tranche internal junior;
    FloatingMarket internal market;
    address[] internal actors;

    uint256 private constant ERC7540_SLOT = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    function setUp() public {
        _deployCap();
        (address m, address t0, address t1) = _createMarket("Queue");
        market = FloatingMarket(m);
        senior = Tranche(t0);
        junior = Tranche(t1);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1e30);

        _fundTranche(t1, makeAddr("juniorLP"), 500e18);
        _fundTranche(t0, makeAddr("seniorLP"), 1_000e18);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i; i < actors.length; ++i) {
            _fundVault(actors[i], 1e24);
            vm.prank(actors[i]);
            vault.setOperator(t0, true);
            _admitDepositor(t0, actors[i]);
            vm.prank(actors[i]);
            senior.deposit(200e18, actors[i]);
        }

        // some standing debt so lockedValue is live from the first call
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        handler = new TrancheQueueHandler(
            senior, junior, market, IHarness(address(this)), defaultBorrower, defaultLiquidator, actors
        );
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](10);
        sels[0] = TrancheQueueHandler.deposit.selector;
        sels[1] = TrancheQueueHandler.request.selector;
        sels[2] = TrancheQueueHandler.transferRequest.selector;
        sels[3] = TrancheQueueHandler.claim4.selector;
        sels[4] = TrancheQueueHandler.claim3.selector;
        sels[5] = TrancheQueueHandler.borrow.selector;
        sels[6] = TrancheQueueHandler.repay.selector;
        sels[7] = TrancheQueueHandler.liquidate.selector;
        sels[8] = TrancheQueueHandler.movePrice.selector;
        sels[9] = TrancheQueueHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: sels }));
    }

    function harnessSetPrice(uint256 p) external {
        _setPrice(address(collateral), p);
    }

    function harnessMintStable(address to, uint256 amount) external {
        stablecoin.mintCreditBacked(to, amount);
    }

    // ── storage readers for controllerRequests (private EnumerableSet) ────────

    function _setSlot(address c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c, ERC7540_SLOT + 6));
    }

    function _setValues(address c) internal view returns (uint256[] memory vals) {
        bytes32 slot = _setSlot(c);
        uint256 len = uint256(vm.load(address(senior), slot));
        vals = new uint256[](len);
        bytes32 data = keccak256(abi.encode(slot));
        for (uint256 i; i < len; ++i) {
            vals[i] = uint256(vm.load(address(senior), bytes32(uint256(data) + i)));
        }
    }

    function _setPosition(address c, uint256 id) internal view returns (uint256) {
        bytes32 slot = bytes32(uint256(_setSlot(c)) + 1);
        return uint256(vm.load(address(senior), keccak256(abi.encode(bytes32(id), slot))));
    }

    function _requestShares(uint256 id) internal view returns (uint256) {
        address c = senior.controllerOf(id);
        return senior.pendingRedeemRequest(id, c) + senior.claimableRedeemRequest(id, c);
    }

    // ── invariants ────────────────────────────────────────────────────────────

    /// I33a: Σ requestShares == redeemQueue − settledQueue
    function invariant_I33_sumOfRequestsIsTheQueue() public view {
        uint256 n = handler.idCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += _requestShares(handler.ids(i));
        }
        assertEq(sum, senior.redemptionQueue(), "I33a: sum requestShares != redemptionQueue");
    }

    /// I33b: escrow balance == redemptionQueue
    function invariant_I33_escrowEqualsQueue() public view {
        assertEq(senior.balanceOf(address(senior)), senior.redemptionQueue(), "I33b: escrow != queue");
    }

    /// I33c: controllerRequests[c] == { id : requestController[id] == c }
    function invariant_I33_setMatchesControllers() public view {
        uint256 m = handler.actorCount();
        for (uint256 j; j < m; ++j) {
            address c = handler.actors(j);
            uint256[] memory vals = _setValues(c);
            for (uint256 i; i < vals.length; ++i) {
                assertEq(senior.controllerOf(vals[i]), c, "I33c: set member not controlled by c");
                assertGt(_requestShares(vals[i]), 0, "I33c: set member is a dead request");
            }
        }
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            address c = senior.controllerOf(id);
            if (c == address(0)) {
                assertEq(senior.pendingRedeemRequest(id, address(0)), 0, "I33c: consumed request still has shares");
            } else {
                assertGt(_setPosition(c, id), 0, "I33c: live request missing from its controller's set");
            }
        }
    }

    /// Each claim ≤ live unlockedSupply at the moment of the claim (H-2 fix).
    function invariant_P3_noClaimExceedsLiveUnlocked() public view {
        assertEq(handler.overclaims(), 0, "a claim exceeded unlockedSupply at claim time");
    }

    /// A claim never moves a healthy market under lt (H-2 consequence).
    function invariant_P3_claimNeverFlipsHealthyToLiquidatable() public view {
        assertEq(handler.healthFlips(), 0, "a queued claim pushed a healthy market under lt");
    }

    /// I26: redeem(maxRedeem(a)) never reverts.
    function invariant_I26_redeemMaxNeverReverts() public view {
        assertEq(handler.i26Violations(), 0, string.concat("redeem(maxRedeem) reverted: ", handler.lastI26Reason()));
    }

    function invariant_report() public view {
        console.log("calls", handler.calls(), "claims", handler.claims());
        console.log("paidShares", handler.paidShares(), "sumUnlockedObserved", handler.sumUnlockedObserved());
    }
}
