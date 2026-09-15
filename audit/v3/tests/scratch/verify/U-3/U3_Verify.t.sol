// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Phase-3 adversarial verification of U-3 (offline, no RPC). Shares the v1 proxies + Migrator harness of
// ../U-1/U1_Verify.t.sol (v1 main @ 695c828 bytecode, OZ 5.4.0).
//
// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/U-3 forge test --match-path 'audit/v3/tests/scratch/verify/U-3/*' -vv
//
// Attacks on the finding:
//  (a) "never / forever": opt-in is one line of the same migration step U-1 already requires; a migration that
//      sets the Wrapper authority but forgets optIn is repaired by a second timelock upgrade; only a *bare*
//      stcUSD upgrade (authority 0 => U-2 brick) makes it permanent.
//  (a) premium funded while staked==0 is frozen, not lost: it vests to whoever opts in afterwards.
//  (b) claimable(stcUSD)==0 before opt-in, so HEAD totalAssets == cUSD.balanceOf(stcUSD); the step at upgrade
//      is exactly (balance - storedTotal) + lockedProfit, and v1 notify()+lockDuration before the batch zeroes it.
//  (c) "one holder takes 100 %" holds only while exactly one account is opted in; it is the P18 opt-in rule.

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../../contracts/cap/Wrapper.sol";
import { IPremiumVesting } from "../../../../../../contracts/interfaces/IPremiumVesting.sol";
import { Migrator, U_VerifyBase } from "../U-1/U1_Verify.t.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/Test.sol";

interface IV1StakedCapView {
    function notify() external;
    function lockedProfit() external view returns (uint256);
    function lockDuration() external view returns (uint256);
    function lastNotify() external view returns (uint256);
}

/// @dev Same out-of-tree intermediate implementation as U-1, split so the Wrapper step can be run
///      with or without the opt-in (to model a migration author who forgot it).
contract Migrator2 is Migrator {
    function setAuthorityOnly(address authority) external {
        _v1Auth();
        assembly { sstore(SLOT_ACCESS_MANAGED, authority) }
    }

    function optInOnly(address premiumVesting) external {
        _v1Auth();
        IPremiumVesting(premiumVesting).optIn();
    }
}

contract U3_Verify is U_VerifyBase {
    bytes32 constant SLOT_STAKED_CAP = 0xc3a6ec7b30f1d79063d00dcbb5942b226b77fe48a28f1a19018e7d1f70fd7600; // storedTotal
    address migrator2;
    uint256 constant YIELD = 100e18;

    function setUp() public override {
        super.setUp();
        migrator2 = address(new Migrator2());
        // v1 yield lands on stcUSD as a plain transfer; notify() starts the 1-day linear vest; half vests.
        vm.prank(bob);
        IERC20(cusd).transfer(stcusd, YIELD);
        IV1StakedCapView(stcusd).notify();
        vm.warp(block.timestamp + 12 hours);
        // a second, un-notified slice (mirrors the live 6,662 cUSD that arrived after the last notify)
        vm.prank(bob);
        IERC20(cusd).transfer(stcusd, YIELD / 2);
    }

    function _migrateCusd() internal {
        UUPSUpgradeable(cusd)
            .upgradeToAndCall(
                migrator,
                abi.encodeCall(
                    Migrator.migrateStablecoin, (address(manager), address(usdc), 6, address(irm), address(0))
                )
            );
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
    }

    function _migrateStcusdAuthorityOnly() internal {
        UUPSUpgradeable(stcusd)
            .upgradeToAndCall(migrator2, abi.encodeCall(Migrator2.setAuthorityOnly, (address(manager))));
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, "");
    }

    // ---------------------------------------------------------------- (a) opt-in is part of the migration step

    function test_a_optInIsOneLineOfTheMigration_premiumFlowsToStcusd() public {
        _twoStepMigrate(); // U-1's path: Migrator.migrateWrapper = set authority + optIn()
        Stablecoin c = Stablecoin(cusd);
        assertTrue(c.optedIn(stcusd), "wrapper opted in by the migration step");
        assertEq(c.stakedSupply(), IERC20(cusd).balanceOf(stcusd), "staked == wrapper balance");

        uint256 taBefore = Wrapper(stcusd).totalAssets();
        c.fundCreditBacked(1_000e18); // this == manager admin; unconfigured selectors default to ADMIN_ROLE
        vm.warp(block.timestamp + 2 days); // ~98 % of the pot vests (12 h time constant)
        uint256 claimable = c.claimable(stcusd);
        assertGt(claimable, 950e18, "stcUSD earns the premium");
        assertEq(Wrapper(stcusd).totalAssets(), taBefore + claimable, "totalAssets = balance + claimable");
        console2.log("claimable(stcUSD) after 2d of a 1,000 premium", claimable);
    }

    function test_a_forgottenOptInIsFrozenNotLost_andRepairableWhileAuthorityIsSet() public {
        _migrateCusd();
        _migrateStcusdAuthorityOnly(); // migration author forgot optIn()
        Stablecoin c = Stablecoin(cusd);
        Wrapper w = Wrapper(stcusd);
        assertFalse(c.optedIn(stcusd), "not opted in");
        assertEq(c.stakedSupply(), 0);

        // premium funded while staked == 0: remainder grows, nothing vests, nothing is lost
        c.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        assertEq(c.claimable(stcusd), 0, "silent: stcUSD earns nothing");
        // remaining() reads ahead (the view ignores supply) but a zero-supply _accrue never deducts from storage:
        // the whole pot is still in `remainder`
        assertEq(c.vested() + c.remaining(), 1_000e18, "pot is frozen in storage, not distributed");
        assertEq(c.premiumPerShare(), 0, "nothing was ever written to per-share");

        // silent failure: the wrapper otherwise works (deposit / redeem at par of its balance)
        vm.startPrank(bob);
        IERC20(cusd).approve(stcusd, type(uint256).max);
        uint256 sh = IERC4626(stcusd).deposit(1e18, bob);
        IERC4626(stcusd).redeem(sh, bob, bob);
        vm.stopPrank();

        // repair: authority is set, so the manager admin can run a second upgrade that calls optIn() as stcUSD
        UUPSUpgradeable(stcusd).upgradeToAndCall(migrator2, abi.encodeCall(Migrator2.optInOnly, (cusd)));
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, "");
        assertTrue(c.optedIn(stcusd), "repaired");
        assertEq(c.stakedSupply(), IERC20(cusd).balanceOf(stcusd));
        assertEq(w.authority(), address(manager));

        // and the frozen pot now vests to stcUSD
        vm.warp(block.timestamp + 2 days);
        assertGt(c.claimable(stcusd), 950e18, "frozen premium flows to the late opt-in");
    }

    function test_a_permanentOnlyWhenStcusdIsBareUpgraded_thatIsU2() public {
        _migrateCusd();
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, ""); // bare: authority stays 0
        Stablecoin c = Stablecoin(cusd);
        assertEq(Wrapper(stcusd).authority(), address(0));
        assertFalse(c.optedIn(stcusd));
        // no second upgrade => no way to ever call optIn as stcUSD: this is U-2's brick, not a new root cause
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        UUPSUpgradeable(stcusd).upgradeToAndCall(migrator2, abi.encodeCall(Migrator2.optInOnly, (cusd)));
        // holders are not trapped: exit at the wrapper's balance-based price still works (cUSD.claim is live)
        vm.prank(alice);
        uint256 out = IERC4626(stcusd).redeem(1e18, alice, alice);
        assertGt(out, 1e18, "exit at par of balance (v1 yield included)");
    }

    // ---------------------------------------------------------------- (b) the totalAssets step

    function test_b_totalAssetsStep_isUnnotifiedPlusLockedProfit_claimableZeroBeforeOptIn() public {
        uint256 bal = IERC20(cusd).balanceOf(stcusd);
        uint256 stored = uint256(vm.load(stcusd, SLOT_STAKED_CAP));
        uint256 locked = IV1StakedCapView(stcusd).lockedProfit();
        uint256 v1TA = IERC4626(stcusd).totalAssets();
        assertEq(v1TA, stored - locked, "v1: storedTotal - lockedProfit");
        assertEq(bal - stored, YIELD / 2, "un-notified slice");
        assertEq(locked, YIELD / 2, "half of the notified slice still vesting");

        _migrateCusd();
        _migrateStcusdAuthorityOnly(); // no opt-in, as the finding assumes
        Stablecoin c = Stablecoin(cusd);
        assertEq(c.claimable(stcusd), 0, "claimable is 0 before opt-in");
        uint256 headTA = Wrapper(stcusd).totalAssets();
        assertEq(headTA, bal, "HEAD totalAssets == cUSD.balanceOf(stcUSD)");
        assertEq(headTA - v1TA, (bal - stored) + locked, "step = un-notified + lockedProfit");
        console2.log("v1 totalAssets", v1TA);
        console2.log("HEAD totalAssets", headTA);
        console2.log("step", headTA - v1TA);
        // live: bal 80,727,427.64  storedTotal 80,720,765.47  => un-notified 6,662.17; lockedProfit 4,669.65 at the
        // author's block => step 11,331.8 (author: 11,335.46 at a slightly earlier block); 0 + 6,662.17 once vested.
    }

    function test_b_notifyAndWaitLockDurationBeforeUpgrade_removesTheStep() public {
        // wait out the current vest, notify the un-notified slice, wait out that vest too
        vm.warp(block.timestamp + 12 hours);
        IV1StakedCapView(stcusd).notify();
        vm.warp(block.timestamp + IV1StakedCapView(stcusd).lockDuration());
        uint256 v1TA = IERC4626(stcusd).totalAssets();
        assertEq(v1TA, IERC20(cusd).balanceOf(stcusd), "v1 already values the full balance");

        _migrateCusd();
        _migrateStcusdAuthorityOnly();
        assertEq(Wrapper(stcusd).totalAssets(), v1TA, "no step");
    }

    // ---------------------------------------------------------------- (c) who takes the premium while stcUSD is out

    function test_c_singleOptedInHolderTakesAllOnlyWhileAlone() public {
        _migrateCusd();
        _migrateStcusdAuthorityOnly();
        Stablecoin c = Stablecoin(cusd);

        vm.prank(alice); // 5,000 cUSD
        c.optIn();
        c.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        uint256 aliceAlone = c.claimable(alice);
        assertGt(aliceAlone, 950e18, "alone: ~100 % of the pot regardless of balance");

        vm.prank(bob); // 10,000 - 150 cUSD, twice alice
        c.optIn();
        c.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        uint256 aliceNow = c.claimable(alice) - aliceAlone;
        uint256 bobNow = c.claimable(bob);
        // 5,000 : 9,850 split of the second pot
        assertApproxEqRel(bobNow * 5_000e18, aliceNow * 9_850e18, 1e15, "second pot pro rata among opted-in");
        console2.log("alone", aliceAlone, "then alice/bob", aliceNow);
        console2.log("bob", bobNow);
    }
}
