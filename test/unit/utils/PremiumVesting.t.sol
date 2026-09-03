// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PremiumVesting } from "../../../contracts/utils/PremiumVesting.sol";
import { WadRayMath } from "../../../contracts/utils/WadRayMath.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Exposes the library against real storage, since every function takes a `Schedule storage`
contract PremiumVestingHarness {
    using PremiumVesting for PremiumVesting.Schedule;

    PremiumVesting.Schedule internal s;

    function open(uint256 epoch) external {
        s.open(epoch);
    }

    function accrue(uint256 supply) external {
        s.accrue(supply);
    }

    function fund(uint256 amount) external {
        s.fund(amount);
    }

    function setPeriod(uint256 epoch) external {
        s.setPeriod(epoch);
    }

    function checkpoint(address account, uint256 balance, uint256 newBalance) external {
        s.checkpoint(account, balance, newBalance);
    }

    function settle(address account, uint256 balance) external returns (uint256) {
        return s.settle(account, balance);
    }

    function claimable(address account, uint256 balance, uint256 supply) external view returns (uint256) {
        return s.claimable(account, balance, supply);
    }

    function unlocked() external view returns (uint256) {
        return s.unlocked();
    }

    function locked() external view returns (uint256) {
        return s.locked();
    }

    function end() external view returns (uint256) {
        return s.end();
    }

    function rate() external view returns (uint256) {
        return s.rate();
    }

    function period() external view returns (uint256) {
        return s.period;
    }

    function start() external view returns (uint256) {
        return s.start;
    }

    function vested() external view returns (uint256) {
        return s.vested;
    }

    function lastUpdate() external view returns (uint256) {
        return s.lastUpdate;
    }

    function perShare() external view returns (uint256) {
        return s.perShare;
    }

    function pending(address account) external view returns (uint256) {
        return s.pending[account];
    }
}

/// @notice Direct tests for the vesting library {Tranche} and {Underwriter} both delegate to.
///
/// Worth having on its own rather than only through the two callers: the library is now the single
/// implementation of the accrual, so a change here breaks both at once, and several of the
/// properties below (that sliding preserves the remainder, that splitting an accrual does not
/// change the total) are invariants the callers rely on without ever stating.
contract PremiumVestingTest is Test {
    using WadRayMath for uint256;

    uint256 internal constant PERIOD = 6 hours;
    uint256 internal constant PREMIUM = 3.1491e18;

    PremiumVestingHarness internal v;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // away from the zero timestamp, so an anchor left at zero could not pass by accident
        vm.warp(1_000_000);
        v = new PremiumVestingHarness();
        v.open(PERIOD);
    }

    function test_open_anchorsAnEmptyEpochAtNow() public view {
        assertEq(v.start(), block.timestamp, "anchored at open, not at the unix epoch");
        assertEq(v.end(), block.timestamp + PERIOD, "one period out");
        assertEq(v.vested(), 0, "with nothing to release");
        assertEq(v.locked(), 0, "nothing held");
        assertEq(v.unlocked(), 0, "and nothing due");
    }

    function test_fund_startsAnEpochNow() public {
        v.fund(PREMIUM);

        assertEq(v.vested(), PREMIUM, "the whole lump is vesting");
        assertEq(v.start(), block.timestamp, "anchored now");
        assertEq(v.end(), block.timestamp + PERIOD, "one period out");
        assertEq(v.locked(), PREMIUM, "and none of it is released yet");
        assertEq(v.unlocked(), 0, "nothing due on arrival");
    }

    function test_releaseIsLinearAcrossTheEpoch() public {
        v.fund(PREMIUM);

        vm.warp(block.timestamp + PERIOD / 4);
        assertEq(v.unlocked(), PREMIUM / 4, "a quarter due");
        assertEq(v.locked(), PREMIUM * 3 / 4, "three quarters held");

        vm.warp(block.timestamp + PERIOD / 4);
        assertEq(v.unlocked(), PREMIUM / 2, "half due");
        assertEq(v.locked(), PREMIUM / 2, "half held");
    }

    function test_releaseStopsAtTheEpochEnd() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD * 5);

        assertEq(v.unlocked(), PREMIUM, "the whole lump came due, and no more");
        assertEq(v.locked(), 0, "nothing held back");

        v.accrue(1_000e18);
        assertEq(v.lastUpdate(), v.end(), "cursor parked on the end, not on now");
        assertEq(v.unlocked(), 0, "and a second accrual releases nothing");
    }

    function test_accrueDividesByTheSupplyPresentAtTheTime() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);

        v.accrue(1_000e18);
        assertEq(v.perShare(), (PREMIUM / 2).rayDiv(1_000e18), "half the lump over the supply");
    }

    /// @dev The property the idle-window fix rests on. Sliding moves `start` and `lastUpdate` by the
    /// same delta, so `end - lastUpdate` is unchanged and the remaining fraction is untouched.
    function test_idleWindowSlidesTheEpochRatherThanBurningIt() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);

        v.accrue(1_000e18);
        uint256 heldBefore = v.locked();
        uint256 endBefore = v.end();
        assertApproxEqAbs(heldBefore, PREMIUM / 2, 1, "half still held");

        // a stretch with nothing staked
        vm.warp(block.timestamp + PERIOD * 3);
        v.accrue(0);

        assertEq(v.end(), endBefore + PERIOD * 3, "the epoch slid by exactly the idle time");
        assertEq(v.vested(), PREMIUM, "with nothing burned");
        assertEq(v.locked(), heldBefore, "and the same amount still held back");
        assertEq(v.unlocked(), 0, "no cliff waiting for the next depositor");
    }

    /// @dev The corollary: because sliding leaves {locked} equal to the un-released remainder, a
    /// re-vest over an idle window carries all of it. Freezing the clock would have dropped it.
    function test_reVestingOverAnIdleWindowCarriesEverything() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        uint256 held = v.locked();
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(0);

        v.setPeriod(1 hours);
        assertEq(v.vested(), held, "the remainder was carried into the new period");
        assertEq(v.period(), 1 hours, "over the new period");
        assertEq(v.end(), block.timestamp + 1 hours, "restarted from now");
    }

    function test_fundAddsToWhatIsStillHeld() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        uint256 held = v.locked();
        v.fund(PREMIUM);

        assertEq(v.vested(), held + PREMIUM, "top-up stacks on the remainder");
        assertEq(v.end(), block.timestamp + PERIOD, "and the epoch restarts");
    }

    /// @dev Shortening a period can put the new end behind where the cursor already sits, which is
    /// why {accrue} clamps instead of assuming the end only moves forward.
    function test_shorteningThePeriodCannotStrandTheCursorAhead() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        v.setPeriod(1);
        vm.warp(block.timestamp + 10);
        v.accrue(1_000e18);

        assertEq(v.lastUpdate(), v.end(), "cursor clamped to the end");
        assertEq(v.locked(), 0, "epoch fully released");
    }

    /// @dev Splitting an accrual must not change what gets released, or the timing of unrelated
    /// calls that happen to poke the schedule would move premium between holders.
    function testFuzz_splittingAnAccrualDoesNotChangeTheTotal(uint8 steps) public {
        uint256 count = uint256(steps) % 20 + 2;
        uint256 supply = 1_000e18;

        v.fund(PREMIUM);
        uint256 startedAt = block.timestamp;

        for (uint256 i = 1; i <= count; ++i) {
            vm.warp(startedAt + PERIOD * i / count);
            v.accrue(supply);
        }
        uint256 split = v.perShare();

        PremiumVestingHarness single = new PremiumVestingHarness();
        vm.warp(startedAt);
        single.open(PERIOD);
        single.fund(PREMIUM);
        vm.warp(startedAt + PERIOD);
        single.accrue(supply);

        // each step floors its own slice, so splitting can only lose dust, never gain
        assertLe(split, single.perShare(), "splitting never releases more");
        assertApproxEqAbs(split, single.perShare(), count * 1e9, "and loses only rounding dust");
    }

    function test_checkpointBanksEarningsBeforeTheBalanceMoves() public {
        v.fund(PREMIUM);
        v.checkpoint(alice, 0, 100e18);

        vm.warp(block.timestamp + PERIOD);
        v.accrue(100e18);

        uint256 owed = v.claimable(alice, 100e18, 100e18);
        assertApproxEqAbs(owed, PREMIUM, 1e6, "sole holder earns the lump");

        // alice halves her position; what she already earned is banked, not rebased
        v.checkpoint(alice, 100e18, 50e18);
        assertApproxEqAbs(v.pending(alice), owed, 1, "earnings preserved across the change");
        assertApproxEqAbs(v.claimable(alice, 50e18, 50e18), owed, 1, "and still owed on the new balance");
    }

    function test_holdersSplitPremiumByBalance() public {
        v.checkpoint(alice, 0, 75e18);
        v.checkpoint(bob, 0, 25e18);

        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        v.accrue(100e18);

        uint256 toAlice = v.claimable(alice, 75e18, 100e18);
        uint256 toBob = v.claimable(bob, 25e18, 100e18);

        assertApproxEqRel(toAlice, PREMIUM * 3 / 4, 1e12, "three quarters to the larger holder");
        assertApproxEqRel(toBob, PREMIUM / 4, 1e12, "a quarter to the smaller");
        assertLe(toAlice + toBob, PREMIUM, "and never more than was funded");
    }

    function test_settleZeroesTheEntitlementAndPaysItOnce() public {
        v.checkpoint(alice, 0, 100e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        v.accrue(100e18);

        uint256 owed = v.claimable(alice, 100e18, 100e18);
        assertEq(v.settle(alice, 100e18), owed, "settle pays what was claimable");
        assertEq(v.claimable(alice, 100e18, 100e18), 0, "nothing left owed");
        assertEq(v.settle(alice, 100e18), 0, "and it cannot be drawn twice");
    }

    /// @dev {settle} reads settled state where {claimable} projects, so the caller has to accrue
    /// first. This pins that the two agree once it has, including past the epoch end where
    /// `lastUpdate` parks on the end rather than on now.
    function test_claimableAgreesWithSettleAfterAccrual() public {
        v.checkpoint(alice, 0, 100e18);
        v.fund(PREMIUM);

        vm.warp(block.timestamp + PERIOD * 2);
        v.accrue(100e18);
        assertTrue(v.lastUpdate() != block.timestamp, "cursor is behind now, the awkward case");

        uint256 projected = v.claimable(alice, 100e18, 100e18);
        assertEq(v.settle(alice, 100e18), projected, "projection matches the settled figure");
    }

    function test_rateIsNominalAndAccrualDoesNotUseIt() public {
        // a lump that does not divide evenly, so a truncated rate would visibly under-release
        uint256 awkward = PERIOD * 2 - 1;
        v.fund(awkward);

        assertEq(v.rate(), 1, "nominal rate truncates to 1 wei per second");

        vm.warp(block.timestamp + PERIOD / 2);
        // a truncated rate would release PERIOD / 2 wei over this window; scaling the lump by
        // elapsed time releases very nearly half of it, which is almost twice as much
        assertEq(v.unlocked(), awkward / 2, "release comes off the lump, not off the rate");
        assertGt(v.unlocked(), v.rate() * (PERIOD / 2), "strictly more than the rate would give");
    }
}
