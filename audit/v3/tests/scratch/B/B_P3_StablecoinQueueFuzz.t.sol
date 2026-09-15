// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface IStableHarness {
    function mintCredit(address to, uint256 amount) external;
    function burnCredit(address from, uint256 amount) external;
    function badDebtReserve(uint256 amount) external;
}

/// @notice Stablecoin queue handler: the same request/claim ops plus credit mint/burn, bad-debt
/// recognition, reserve removal (simulated `invest`), permissionless `fund`, `coverBadDebt`, and
/// opt-in/out. Ghosts as in the tranche handler.
contract StableQueueHandler is Test {
    Stablecoin public s;
    MockERC20 public usdc;
    IStableHarness internal harness;
    address internal borrower;
    address[] public actors;
    uint256[] public ids;

    uint256 public overclaims;
    uint256 public i26Violations;
    uint256 public claims;
    uint256 public calls;
    string public lastI26Reason;

    constructor(Stablecoin _s, MockERC20 _usdc, IStableHarness _h, address _borrower, address[] memory _actors) {
        s = _s;
        usdc = _usdc;
        harness = _h;
        borrower = _borrower;
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
            if (s.controllerOf(cand) == c) return cand;
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        calls++;
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 200e18);
        usdc.mint(a, amount);
        vm.startPrank(a);
        usdc.approve(address(s), amount);
        s.deposit(amount, a);
        vm.stopPrank();
    }

    function request(uint256 actorSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 bal = s.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bal * bound(frac, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(a);
        ids.push(s.requestRedeem(shares, a, a));
    }

    function transferRequest(uint256 actorSeed, uint256 idSeed, uint256 toSeed) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 id = _ownedId(a, idSeed);
        if (id == 0) return;
        vm.prank(a);
        s.transferRequest(id, _actor(toSeed));
    }

    function claim4(uint256 actorSeed, uint256 idSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 id = _ownedId(a, idSeed);
        if (id == 0) return;
        uint256 claimable = s.claimableRedeemRequest(id, a);
        if (claimable == 0) return;
        uint256 shares = claimable * bound(frac, 1, 10_000) / 10_000;
        if (shares == 0) return;
        _claim(a, id, shares, true);
    }

    function claim3(uint256 actorSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 max = s.maxRedeem(a);
        if (max == 0) return;
        uint256 f = bound(frac, 1, 10_000);
        uint256 shares = max * f / 10_000;
        if (shares == 0) return;
        _claim(a, 0, shares, f == 10_000);
    }

    function withdraw3Max(uint256 actorSeed) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 maxAssets = s.maxWithdraw(a);
        if (maxAssets == 0) return;
        uint256 unlockedBefore = s.unlockedSupply();
        vm.prank(a);
        try s.withdraw(maxAssets, a, a) returns (uint256 shares) {
            claims++;
            if (shares > unlockedBefore) overclaims++;
        } catch (bytes memory e) {
            i26Violations++;
            lastI26Reason = string.concat("withdraw(maxWithdraw): ", vm.toString(e));
        }
    }

    function _claim(address a, uint256 id, uint256 shares, bool mustSucceed) internal {
        uint256 unlockedBefore = s.unlockedSupply();
        bool ok;
        bytes memory err;
        vm.prank(a);
        if (id == 0) {
            try s.redeem(shares, a, a) {
                ok = true;
            }
                catch (bytes memory e) {
                err = e;
            }
        } else {
            try s.redeem(id, shares, a, a) {
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
        if (shares > unlockedBefore) overclaims++;
    }

    function instantRedeem(uint256 actorSeed, uint256 frac) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 max = s.maxInstantRedeem(a);
        if (max == 0) return;
        uint256 shares = max * bound(frac, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(a);
        try s.instantRedeem(shares, a, a) { }
        catch (bytes memory e) {
            i26Violations++;
            lastI26Reason = string.concat("instantRedeem<=max: ", vm.toString(e));
        }
    }

    function mintCredit(uint256 amount) external {
        calls++;
        harness.mintCredit(borrower, bound(amount, 1, 500e18));
    }

    function burnCredit(uint256 frac) external {
        calls++;
        uint256 c = s.creditBackedSupply();
        uint256 bal = s.balanceOf(borrower);
        uint256 maxBurn = c < bal ? c : bal;
        if (maxBurn == 0) return;
        uint256 amount = maxBurn * bound(frac, 1, 10_000) / 10_000;
        if (amount == 0) return;
        harness.burnCredit(borrower, amount);
    }

    function badDebtReserve(uint256 frac) external {
        calls++;
        // the contract only checks badDebt <= totalSupply; an honest guardian cannot recognise a
        // reserve loss larger than the reserve-backed supply, so the handler keeps I35 itself.
        // The unbounded version is the deterministic PoC below (B_I35_GuardianOverRecognition).
        uint256 locked = s.badDebt() + s.creditBackedSupply();
        uint256 supply = s.totalSupply();
        if (supply <= locked) return;
        uint256 cap = (supply - locked) / 10;
        if (cap == 0) return;
        uint256 amount = cap * bound(frac, 1, 10_000) / 10_000;
        if (amount == 0) return;
        harness.badDebtReserve(amount);
    }

    function coverBadDebt(uint256 actorSeed, uint256 frac) external {
        calls++;
        if (s.badDebt() == 0) return;
        address a = _actor(actorSeed);
        uint256 bal = s.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bal * bound(frac, 1, 10_000) / 10_000;
        if (amount == 0) return;
        vm.prank(a);
        s.coverBadDebt(amount);
    }

    /// simulated `invest`: reserve leaves the contract, unlockedSupply is capped by what is on hand
    function burnReserve(uint256 frac) external {
        calls++;
        uint256 bal = usdc.balanceOf(address(s));
        if (bal == 0) return;
        uint256 amount = bal * bound(frac, 1, 5_000) / 10_000;
        if (amount == 0) return;
        usdc.burn(address(s), amount);
    }

    function returnReserve(uint256 amount) external {
        calls++;
        usdc.mint(address(s), bound(amount, 1, 100e18));
    }

    function fund(uint256 actorSeed, uint256 amount) external {
        calls++;
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 10e18);
        usdc.mint(a, amount);
        vm.startPrank(a);
        usdc.approve(address(s), amount);
        s.fund(amount);
        vm.stopPrank();
    }

    function optIn(uint256 actorSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        s.optIn();
    }

    function optOut(uint256 actorSeed) external {
        calls++;
        vm.prank(_actor(actorSeed));
        s.optOut();
    }

    function claimPremium(uint256 actorSeed) external {
        calls++;
        address a = _actor(actorSeed);
        vm.prank(a);
        s.claim(a);
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 1 days));
    }
}

/// forge-config: default.invariant.runs = 80
/// forge-config: default.invariant.depth = 300
/// forge-config: default.invariant.fail-on-revert = true
contract B_P3_StablecoinQueueFuzz is CapDeployer {
    StableQueueHandler internal handler;
    address[] internal actors;
    address internal borrower = makeAddr("creditHolder");

    uint256 private constant ERC7540_SLOT = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    function setUp() public {
        _deployCap();
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i; i < actors.length; ++i) {
            _depositStable(actors[i], 500e18);
        }
        stablecoin.mintCreditBacked(borrower, 800e18);

        handler = new StableQueueHandler(stablecoin, cusdUnderlying, IStableHarness(address(this)), borrower, actors);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](18);
        sels[0] = StableQueueHandler.deposit.selector;
        sels[1] = StableQueueHandler.request.selector;
        sels[2] = StableQueueHandler.transferRequest.selector;
        sels[3] = StableQueueHandler.claim4.selector;
        sels[4] = StableQueueHandler.claim3.selector;
        sels[5] = StableQueueHandler.withdraw3Max.selector;
        sels[6] = StableQueueHandler.instantRedeem.selector;
        sels[7] = StableQueueHandler.mintCredit.selector;
        sels[8] = StableQueueHandler.burnCredit.selector;
        sels[9] = StableQueueHandler.badDebtReserve.selector;
        sels[10] = StableQueueHandler.coverBadDebt.selector;
        sels[11] = StableQueueHandler.burnReserve.selector;
        sels[12] = StableQueueHandler.returnReserve.selector;
        sels[13] = StableQueueHandler.fund.selector;
        sels[14] = StableQueueHandler.optIn.selector;
        sels[15] = StableQueueHandler.optOut.selector;
        sels[16] = StableQueueHandler.claimPremium.selector;
        sels[17] = StableQueueHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: sels }));
    }

    function mintCredit(address to, uint256 amount) external {
        stablecoin.mintCreditBacked(to, amount);
    }

    function burnCredit(address from, uint256 amount) external {
        stablecoin.burnCreditBacked(from, amount);
    }

    function badDebtReserve(uint256 amount) external {
        stablecoin.recognizeBadDebtInReserve(amount);
    }

    function _setSlot(address c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c, ERC7540_SLOT + 6));
    }

    function _setValues(address c) internal view returns (uint256[] memory vals) {
        bytes32 slot = _setSlot(c);
        uint256 len = uint256(vm.load(address(stablecoin), slot));
        vals = new uint256[](len);
        bytes32 data = keccak256(abi.encode(slot));
        for (uint256 i; i < len; ++i) {
            vals[i] = uint256(vm.load(address(stablecoin), bytes32(uint256(data) + i)));
        }
    }

    function _setPosition(address c, uint256 id) internal view returns (uint256) {
        bytes32 slot = bytes32(uint256(_setSlot(c)) + 1);
        return uint256(vm.load(address(stablecoin), keccak256(abi.encode(bytes32(id), slot))));
    }

    function _requestShares(uint256 id) internal view returns (uint256) {
        address c = stablecoin.controllerOf(id);
        return stablecoin.pendingRedeemRequest(id, c) + stablecoin.claimableRedeemRequest(id, c);
    }

    function invariant_I33_sumOfRequestsIsTheQueue() public view {
        uint256 n = handler.idCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += _requestShares(handler.ids(i));
        }
        assertEq(sum, stablecoin.redemptionQueue(), "I33a");
    }

    function invariant_I33_setMatchesControllers() public view {
        uint256 m = handler.actorCount();
        for (uint256 j; j < m; ++j) {
            address c = handler.actors(j);
            uint256[] memory vals = _setValues(c);
            for (uint256 i; i < vals.length; ++i) {
                assertEq(stablecoin.controllerOf(vals[i]), c, "I33c: member not controlled by c");
                assertGt(_requestShares(vals[i]), 0, "I33c: dead member");
            }
        }
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            address c = stablecoin.controllerOf(id);
            if (c != address(0)) assertGt(_setPosition(c, id), 0, "I33c: live request missing from set");
        }
    }

    /// I34: escrow + premium pot never exceed what the contract holds of itself
    function invariant_I34_selfBalanceCoversQueueAndRemaining() public view {
        assertGe(
            stablecoin.balanceOf(address(stablecoin)),
            stablecoin.redemptionQueue() + stablecoin.remaining(),
            "I34: self balance < queue + remaining"
        );
    }

    /// I35
    function invariant_I35_creditPlusBadDebtWithinSupply() public view {
        assertLe(stablecoin.creditBackedSupply() + stablecoin.badDebt(), stablecoin.totalSupply(), "I35");
    }

    /// unlocked never exceeds the shares the on-hand reserve can pay
    function invariant_unlockedWithinReserve() public view {
        assertLe(
            stablecoin.unlockedSupply(),
            stablecoin.quoteWithdraw(cusdUnderlying.balanceOf(address(stablecoin))),
            "unlocked > on-hand reserve"
        );
    }

    function invariant_P3_noOverclaim() public view {
        assertEq(handler.overclaims(), 0, "claim exceeded live unlocked");
    }

    function invariant_I26_maxClaimsNeverRevert() public view {
        assertEq(handler.i26Violations(), 0, string.concat("I26: ", handler.lastI26Reason()));
    }

    function invariant_report() public view {
        console.log("calls", handler.calls(), "claims", handler.claims());
    }
}

/// @notice Deterministic reproduction of what the unbounded handler found: GUARDIAN can recognise
/// reserve bad debt up to `totalSupply` even though only `totalSupply - creditBackedSupply` is
/// reserve-backed; a borrower's ordinary repay then takes `totalSupply` below `badDebt` and
/// `backing()` underflows in every conversion.
contract B_I35_GuardianOverRecognition is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_I35_overRecognitionThenRepayBricksConversions() public {
        address holder = makeAddr("holder");
        address borrower = makeAddr("borrower");
        _depositStable(holder, 100e18); // reserve-backed supply 100
        stablecoin.mintCreditBacked(borrower, 900e18); // credit-backed supply 900

        // guardian recognises a 500 reserve loss: accepted, though the reserve backs only 100
        stablecoin.recognizeBadDebtInReserve(500e18);
        assertGt(
            stablecoin.creditBackedSupply() + stablecoin.badDebt(),
            stablecoin.totalSupply(),
            "I35 violated by the guardian"
        );

        // conversions still work at this point
        stablecoin.totalAssets();

        // the borrower repays 600 (permissionless burnCreditBacked via a market; done directly here)
        stablecoin.burnCreditBacked(borrower, 600e18);
        assertLt(stablecoin.totalSupply(), stablecoin.badDebt(), "supply now below badDebt");

        vm.expectRevert(); // panic 0x11 in backing()
        stablecoin.totalAssets();
        vm.expectRevert();
        stablecoin.convertToAssets(1e18);
        vm.expectRevert();
        stablecoin.maxWithdraw(holder);
        vm.prank(holder);
        vm.expectRevert();
        stablecoin.instantRedeem(1e18, holder, holder);

        // coverBadDebt cannot repair it (burns supply and badDebt together); a fresh deposit can
        _depositStable(makeAddr("rescuer"), 200e18);
        stablecoin.totalAssets();
    }
}
