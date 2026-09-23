// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IPremiumVesting } from "../../../contracts/interfaces/IPremiumVesting.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { PremiumVesting } from "../../../contracts/utils/PremiumVesting.sol";
import { WadRayMath } from "../../../contracts/utils/WadRayMath.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Exposes the schedule internals against real storage
contract PremiumVestingHarness is PremiumVesting {
    function _transferIn(address, uint256) internal override { }

    function _transferOut(address, uint256) internal override { }

    function totalAssets() public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    function initialize(IERC20 asset, address premium) external initializer {
        __PremiumVesting_init(address(new AccessManager(msg.sender)), asset, "Vault", "VLT", premium, 12 hours);
    }

    function initializeWithPeriod(IERC20 asset, uint256 period_) external initializer {
        __PremiumVesting_init(address(new AccessManager(msg.sender)), asset, "Vault", "VLT", address(asset), period_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function accrue(uint256 supply) external {
        _accrue(_getPremiumVestingStorage(), supply);
    }

    function fund(uint256 amount) external {
        _fund(amount);
    }

    function checkpoint(address account, uint256 balance, uint256 newBalance) external {
        _checkpoint(_getPremiumVestingStorage(), account, balance, newBalance);
    }

    function settle(address account, uint256 balance) external returns (uint256) {
        return _settle(_getPremiumVestingStorage(), account, balance);
    }

    function claimable(address account, uint256 balance, uint256 supply) external view returns (uint256) {
        return _claimable(_getPremiumVestingStorage(), account, balance, supply);
    }

    function rate() external view returns (uint256) {
        return premiumPerSecond();
    }

    function period() external view returns (uint256) {
        return vestingPeriod();
    }

    function remainder() external view returns (uint256) {
        return _getPremiumVestingStorage().remainder;
    }

    function lastUpdate() external view returns (uint256) {
        return lastPremiumUpdate();
    }

    function perShare() external view returns (uint256) {
        return premiumPerShare();
    }

    function pending(address account) external view returns (uint256) {
        return pendingPremium(account);
    }
}

/// @notice Direct tests for the vesting schedule {Tranche} and {Underwriter} both inherit.
contract PremiumVestingTest is Test {
    using WadRayMath for uint256;

    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant PREMIUM = 3.1491e18;
    uint256 internal constant RAY = 1e27;

    PremiumVestingHarness internal v;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        v = _newVesting();
    }

    function _newVesting() internal returns (PremiumVestingHarness instance) {
        instance = new PremiumVestingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18);
        instance.initialize(IERC20(address(token)), address(token));
    }

    function _vested(uint256 pot, uint256 elapsed) internal pure returns (uint256 amount) {
        uint256 retention = RAY - RAY / PERIOD;
        uint256 weight = RAY - retention.rayPow(elapsed);
        amount = Math.mulDiv(pot, weight, RAY, Math.Rounding.Floor);
    }

    function _untilSettled() internal pure returns (uint256 quiet) {
        quiet = 20 * PERIOD;
    }

    function _earn(address who, uint256 shares) internal {
        v.mint(who, shares);
        vm.prank(who);
        v.optIn();
    }

    function test_startsEmpty() public view {
        assertEq(v.remainder(), 0, "nothing held");
        assertEq(v.remaining(), 0, "nothing projected");
        assertEq(v.vested(), 0, "and nothing due");
        assertEq(v.period(), 12 hours, "the initial period is twelve hours");
        assertEq(v.lastUpdate(), 0, "clock starts on the first fund");
        assertEq(IPremiumVesting(address(v)).premiumPerShare(), 0);
        assertEq(IPremiumVesting(address(v)).pendingPremium(address(this)), 0);
    }

    /// @dev Compare changing the period with explicitly settling the old schedule first.
    function testFuzz_setVestingPeriod_checkpointsTheOldSchedule(uint32 rawElapsed, uint32 rawPeriod) public {
        uint256 elapsed = bound(rawElapsed, 1, 3 * PERIOD);
        uint256 newPeriod = bound(rawPeriod, 1, 365 days);
        _earn(alice, 1e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + elapsed);
        uint256 vestedBefore = v.vested();
        uint256 owedBefore = v.claimable(alice);

        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(vestedBefore * 1e9, PREMIUM - vestedBefore, 1e18);
        vm.expectEmit(address(v));
        emit IPremiumVesting.SetVestingPeriod(newPeriod);
        v.setVestingPeriod(newPeriod);

        assertEq(v.remainder(), PREMIUM - vestedBefore);
        assertEq(v.lastUpdate(), block.timestamp);
        assertEq(v.claimable(alice), owedBefore, "past earnings are preserved");
        assertEq(v.vested(), 0, "the new rate starts now");
        assertEq(v.period(), newPeriod);
        vm.warp(block.timestamp + newPeriod);
        uint256 weight = RAY - (RAY - RAY / newPeriod).rayPow(newPeriod);
        assertEq(v.vested(), Math.mulDiv(PREMIUM - vestedBefore, weight, RAY));
    }

    function test_setVestingPeriod_idlePotDoesNotReleaseRetroactively() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + 30 days);
        v.setVestingPeriod(1 days);
        assertEq(v.remaining(), PREMIUM);
        assertEq(v.vested(), 0);
        _earn(alice, 1e18);
        assertEq(v.claimable(alice), 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(v.claimable(alice), PREMIUM * 632 / 1000, 0.001e18);
    }

    function test_setVestingPeriod_rejectsInvalidBoundsWithoutCheckpointing() public {
        _earn(alice, 1e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        uint256 last = v.lastUpdate();
        vm.expectRevert(IPremiumVesting.InvalidVestingPeriod.selector);
        v.setVestingPeriod(0);
        vm.expectRevert(IPremiumVesting.InvalidVestingPeriod.selector);
        v.setVestingPeriod(RAY + 1);
        assertEq(v.lastUpdate(), last);
        assertEq(v.remainder(), PREMIUM);
        assertEq(v.period(), PERIOD);
    }

    function test_setVestingPeriod_acceptsBothEndpoints() public {
        v.setVestingPeriod(RAY);
        assertEq(v.period(), RAY);
        v.setVestingPeriod(1);
        _earn(alice, 1e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + 1);
        assertEq(v.vested(), PREMIUM, "one-second period releases the whole pot next second");
    }

    function test_initializeWithPeriod_rejectsInvalidBounds() public {
        PremiumVestingHarness invalid = new PremiumVestingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18);
        vm.expectRevert(IPremiumVesting.InvalidVestingPeriod.selector);
        invalid.initializeWithPeriod(IERC20(address(token)), 0);
        vm.expectRevert(IPremiumVesting.InvalidVestingPeriod.selector);
        invalid.initializeWithPeriod(IERC20(address(token)), RAY + 1);
        invalid.initializeWithPeriod(IERC20(address(token)), 7 days);
        assertEq(invalid.vestingPeriod(), 7 days);
    }

    function test_setVestingPeriod_requiresAuthority() public {
        vm.prank(bob);
        vm.expectRevert();
        v.setVestingPeriod(1 days);
        assertEq(v.period(), PERIOD);
    }

    function test_fund_addsToTheRemainderWithoutStartingAnEpoch() public {
        vm.expectEmit(address(v));
        emit IPremiumVesting.Fund(address(this), PREMIUM);
        v.fund(PREMIUM);

        assertEq(v.remainder(), PREMIUM, "the whole amount is the remainder");
        assertEq(v.remaining(), PREMIUM, "and none of it is released yet");
        assertEq(v.vested(), 0, "nothing due on arrival");
    }

    function test_releaseIsExponentialInTheTimeConstant() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);

        vm.warp(block.timestamp + PERIOD / 2);
        assertEq(v.vested(), _vested(PREMIUM, PERIOD / 2), "half a window is not half the pot");
        assertGt(v.remaining(), PREMIUM / 2, "more than half is still held");

        vm.warp(block.timestamp + PERIOD / 2);
        assertEq(v.vested(), _vested(PREMIUM, PERIOD), "one window vests about 63%");
        assertApproxEqRel(v.vested(), PREMIUM * 632 / 1000, 0.01e18, "1 - 1/e");
        assertGt(v.remaining(), 0, "and the rest is still held");
    }

    function test_releaseNeverQuiteFinishes() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);

        uint256 afterOne = v.vested();
        assertLt(afterOne, PREMIUM, "one window is not the whole pot");

        vm.warp(block.timestamp + PERIOD);
        assertGt(v.vested(), afterOne, "another window vests more");
        assertLt(v.vested(), PREMIUM, "and still not all of it");
        assertGt(v.rate(), 0, "so the printed rate is never zero");
    }

    function test_accrueDividesByTheSupplyPresentAtTheTime() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);

        uint256 due = v.vested();
        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(Math.mulDiv(due, RAY, 1_000e18), PREMIUM - due, 1_000e18);
        v.accrue(1_000e18);
        assertEq(v.perShare(), due.rayDiv(1_000e18), "what vested, over the supply");
        assertEq(v.remainder(), PREMIUM - due, "and is taken off the remainder");
    }

    /// @dev Idle time must not vest into nobody, and must not dump the buffer on the next
    /// depositor. Freezing the remainder is both.
    function test_idleWindowFreezesTheRemainder() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        uint256 heldBefore = v.remainder();
        uint256 lastBefore = v.lastUpdate();

        vm.warp(block.timestamp + PERIOD * 3);
        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(v.perShare(), heldBefore, 0);
        v.accrue(0);

        assertEq(v.remainder(), heldBefore, "nothing vested to nobody");
        assertEq(v.lastUpdate(), lastBefore + PERIOD * 3, "the clock still moved");
        assertEq(v.vested(), 0, "so there is no cliff waiting for the next depositor");
        assertEq(v.remaining(), heldBefore, "and the same amount is still held");
    }

    function test_checkpointPrecedesFundingAndStakeChanges() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        uint256 due = v.vested();
        uint256 perShare = Math.mulDiv(due, RAY, 1_000e18);
        uint256 remainder = PREMIUM - due;

        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(perShare, remainder, 1_000e18);
        vm.expectEmit(address(v));
        emit IPremiumVesting.Fund(address(this), PREMIUM);
        v.fund(PREMIUM);
        assertEq(v.remainder(), remainder + PREMIUM, "the funding event adds to the checkpoint remainder");

        vm.warp(block.timestamp + PERIOD);
        due = v.vested();
        perShare += Math.mulDiv(due, RAY, 1_000e18);
        remainder = remainder + PREMIUM - due;
        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(perShare, remainder, 1_000e18);
        vm.expectEmit(address(v));
        emit IPremiumVesting.OptOut(alice);
        vm.prank(alice);
        v.optOut();
        assertEq(v.stakedSupply(), 0, "the checkpoint records the supply before opting out");
        assertEq(v.remainder(), remainder);
    }

    function test_roundedZeroAccrualEmitsOnceWhenTheClockAdvances() public {
        _earn(alice, 1e18);
        v.fund(1);
        vm.warp(block.timestamp + 1);
        assertEq(v.vested(), 0, "elapsed premium rounds down to zero");

        vm.expectEmit(address(v));
        emit IPremiumVesting.PremiumAccrued(0, 1, 1e18);
        vm.prank(bob);
        v.optIn();
        assertEq(v.lastUpdate(), block.timestamp);
        assertEq(v.perShare(), 0);
        assertEq(v.remainder(), 1);

        vm.recordLogs();
        vm.prank(bob);
        v.optIn();
        assertEq(vm.getRecordedLogs().length, 0, "a same-timestamp no-op emits no checkpoint");
    }

    function test_fundAddsWithoutRestarting() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        uint256 held = v.remainder();
        uint256 last = v.lastUpdate();
        v.fund(PREMIUM);

        assertEq(v.remainder(), held + PREMIUM, "top-up stacks on the remainder");
        assertEq(v.lastUpdate(), last, "the decay was not rewound");
    }

    /// @dev A half-pot top-up at the midpoint jumps the remainder and the rate, and does not
    /// re-age the leftover
    function test_aTopUpContributesWithoutResettingAge() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD / 2);
        v.accrue(1_000e18);

        uint256 leftover = v.remainder();
        uint256 vestedBefore = PREMIUM - leftover;
        v.fund(PREMIUM / 2);

        vm.warp(block.timestamp + PERIOD / 2);
        uint256 vestedAfter = v.vested();

        // the leftover and the new money decay together from the add, so the second half-window
        // vests more than the first — the rate jumped — and less than a fresh 1.5 pot would
        assertGt(vestedAfter, vestedBefore, "the rate rose with the remainder");
        assertLt(vestedAfter, _vested(leftover + PREMIUM / 2 + vestedBefore, PERIOD / 2), "the leftover kept its age");
    }

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
        uint256 splitLeft = v.remainder();

        vm.warp(startedAt);
        PremiumVestingHarness single = _newVesting();
        single.fund(PREMIUM);
        vm.warp(startedAt + PERIOD);
        single.accrue(supply);

        assertLe(split, single.perShare(), "splitting never releases more");
        assertApproxEqAbs(split, single.perShare(), count * 1e9, "and loses only rounding dust");
        assertApproxEqAbs(splitLeft, single.remainder(), count, "the remainder agrees too");
    }

    function test_checkpointBanksEarningsBeforeTheBalanceMoves() public {
        v.fund(PREMIUM);
        v.checkpoint(alice, 0, 100e18);

        vm.warp(block.timestamp + _untilSettled());
        v.accrue(100e18);

        uint256 owed = v.claimable(alice, 100e18, 100e18);
        assertApproxEqRel(owed, PREMIUM, 1e12, "sole holder earns essentially the pot");

        v.checkpoint(alice, 100e18, 50e18);
        assertApproxEqAbs(v.pending(alice), owed, 1, "earnings preserved across the change");
        assertApproxEqAbs(v.claimable(alice, 50e18, 50e18), owed, 1, "and still owed on the new balance");
    }

    function test_holdersSplitPremiumByBalance() public {
        v.checkpoint(alice, 0, 75e18);
        v.checkpoint(bob, 0, 25e18);

        v.fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());
        v.accrue(100e18);

        uint256 toAlice = v.claimable(alice, 75e18, 100e18);
        uint256 toBob = v.claimable(bob, 25e18, 100e18);

        assertApproxEqRel(toAlice, PREMIUM * 3 / 4, 1e12, "three quarters to the larger holder");
        assertApproxEqRel(toBob, PREMIUM / 4, 1e12, "a quarter to the smaller");
        assertLe(toAlice + toBob, PREMIUM, "and never more than was funded");
    }

    function test_roundingDownLeavesDustBehindRatherThanOverAttributingIt() public {
        v.checkpoint(alice, 0, 1);
        v.checkpoint(bob, 0, 1);

        v.fund(1);
        vm.warp(block.timestamp + PERIOD);
        v.accrue(2);

        assertEq(v.claimable(alice, 1, 2) + v.claimable(bob, 1, 2), 0, "a wei that will not divide is owed to neither");
    }

    /// @dev The callers' clamp is still load-bearing: `debt` floors, so an account arriving
    /// against a mid-stream per-share figure is charged less than its share of what has already
    /// been released. The linear-epoch construction that used to pay 5 against 4 funded does not
    /// survive a remainder that never quite empties, but the rounding gap is the same arithmetic.
    function test_arrivingMidStreamIsChargedAFlooredDebt() public {
        v.fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        v.accrue(1e27);

        uint256 perShare = v.perShare();
        assertGt(perShare, 0, "something has already been released");

        v.checkpoint(alice, 0, 1);
        // one share against a per-share figure that is not a whole wei is charged nothing
        assertEq(v.pending(alice), 0, "nothing banked on arrival");
        assertLt(perShare, RAY, "the figure she arrived against is a fraction of a wei");
    }

    function test_settleZeroesTheEntitlementAndPaysItOnce() public {
        v.checkpoint(alice, 0, 100e18);
        v.fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());
        v.accrue(100e18);

        uint256 owed = v.claimable(alice, 100e18, 100e18);
        assertEq(v.settle(alice, 100e18), owed, "settle pays what was claimable");
        assertEq(v.claimable(alice, 100e18, 100e18), 0, "nothing left owed");
        assertEq(v.settle(alice, 100e18), 0, "and it cannot be drawn twice");
    }

    function test_claimableAgreesWithSettleAfterAccrual() public {
        v.checkpoint(alice, 0, 100e18);
        v.fund(PREMIUM);

        vm.warp(block.timestamp + PERIOD * 2);
        v.accrue(100e18);
        assertEq(v.lastUpdate(), block.timestamp, "cursor sits on now; there is no end to park on");

        uint256 projected = v.claimable(alice, 100e18, 100e18);
        assertEq(v.settle(alice, 100e18), projected, "projection matches the settled figure");
    }

    function test_rateTracksTheRemainder() public {
        _earn(alice, 1_000e18);
        v.fund(PREMIUM);
        assertEq(v.rate(), PREMIUM / PERIOD, "starts at remainder / period");

        vm.warp(block.timestamp + PERIOD);
        assertLt(v.rate(), PREMIUM / PERIOD, "and falls as the remainder falls");
        assertGt(v.rate(), 0, "without hitting zero");
    }

    /// @dev Views used to project a vest while {_accrue} froze. With nobody earning they
    /// must report the stored pot, and settlement must not release it.
    function test_viewsFreezeWhileNobodyIsEarning() public {
        v.fund(100e18);
        vm.warp(block.timestamp + PERIOD);

        assertEq(v.stakedSupply(), 0);
        assertEq(v.vested(), 0, "nothing is available to write");
        assertEq(v.remaining(), 100e18, "the whole pot is still locked");
        assertEq(v.remainder(), 100e18);

        v.accrue(0);
        assertEq(v.remainder(), 100e18, "settlement left the pot untouched");
        assertEq(v.perShare(), 0);
        assertEq(v.vested(), 0);
        assertEq(v.remaining(), 100e18);
    }
}

/// @notice Public opt-in, transfer and claim surface that the schedule tests never mint against.
contract PremiumVestingOptInTest is Test {
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant PREMIUM = 3.1491e18;

    PremiumVestingHarness internal v;
    MockERC20 internal premium;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        MockERC20 asset = new MockERC20("Collateral", "COL", 18);
        premium = new MockERC20("Cap USD", "cUSD", 18);
        v = new PremiumVestingHarness();
        v.initialize(IERC20(address(asset)), address(premium));
    }

    function _stake(address who, uint256 shares) internal {
        v.mint(who, shares);
        vm.prank(who);
        v.optIn();
    }

    function _fund(uint256 amount) internal {
        premium.mint(address(v), amount);
        v.fund(amount);
    }

    function _untilSettled() internal pure returns (uint256 quiet) {
        quiet = 20 * PERIOD;
    }

    function test_optInAddsTheCallersBalanceToStakedSupply() public {
        v.mint(alice, 100e18);
        assertEq(v.stakedSupply(), 0);
        assertFalse(v.optedIn(alice));

        vm.expectEmit(true, false, false, true);
        emit IPremiumVesting.OptIn(alice);
        vm.prank(alice);
        v.optIn();

        assertTrue(v.optedIn(alice));
        assertEq(v.stakedSupply(), 100e18);
        assertEq(v.claimable(alice), 0);
    }

    function test_optInIsANoOpIfAlreadyIn() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        v.optIn();
        assertEq(v.stakedSupply(), 100e18);
    }

    function test_optInWithZeroBalanceThenMintKeepsStakedInStep() public {
        vm.prank(alice);
        v.optIn();
        assertTrue(v.optedIn(alice));
        assertEq(v.stakedSupply(), 0);

        v.mint(alice, 40e18);
        assertEq(v.stakedSupply(), 40e18);
    }

    function test_optInDoesNotPayTheWindowBeforeTheCall() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);

        v.mint(bob, 100e18);
        vm.prank(bob);
        v.optIn();

        assertEq(v.claimable(bob), 0, "the window before opt-in is not his");
        assertGt(v.claimable(alice), 0, "it belongs to whoever was already in");
    }

    function test_deadShareHolderCannotOptIn() public {
        v.mint(DeadShares.HOLDER, 1e3);
        vm.prank(DeadShares.HOLDER);
        v.optIn();
        assertFalse(v.optedIn(DeadShares.HOLDER));
        assertEq(v.stakedSupply(), 0);
    }

    function test_theVaultItselfCannotOptIn() public {
        v.mint(address(v), 50e18);
        vm.prank(address(v));
        v.optIn();
        assertFalse(v.optedIn(address(v)));
        assertEq(v.stakedSupply(), 0);
    }

    function test_optOutBanksEarningsAndStopsTheBalanceEarning() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);

        uint256 owed = v.claimable(alice);
        assertGt(owed, 0);

        vm.expectEmit(true, false, false, true);
        emit IPremiumVesting.OptOut(alice);
        vm.prank(alice);
        v.optOut();

        assertFalse(v.optedIn(alice));
        assertEq(v.stakedSupply(), 0);
        assertEq(v.claimable(alice), owed, "what was earned is still payable");

        vm.warp(block.timestamp + PERIOD);
        assertEq(v.claimable(alice), owed, "and nothing more accrues while she is out");
    }

    function test_optOutIsANoOpIfAlreadyOut() public {
        vm.prank(alice);
        v.optOut();
        assertFalse(v.optedIn(alice));
        assertEq(v.stakedSupply(), 0);
    }

    function test_claimAfterOptOutPaysPendingOnly() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());

        uint256 owed = v.claimable(alice);
        vm.prank(alice);
        v.optOut();

        vm.prank(alice);
        uint256 paid = v.claim(alice);
        assertApproxEqAbs(paid, owed, 1);
        assertEq(v.claimable(alice), 0);
        assertEq(premium.balanceOf(alice), paid);
    }

    function test_reOptInDoesNotCollectTheGap() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);

        vm.prank(alice);
        v.optOut();
        uint256 lockedAfterExit = v.remaining();

        vm.warp(block.timestamp + PERIOD);
        // the idle accrual freezes, so opting back in does not unlock the missed window
        vm.prank(alice);
        v.optIn();
        assertEq(v.claimable(alice), 0, "the gap is not hers");
        assertEq(v.remaining(), lockedAfterExit, "and the remainder was not dumped on her");

        vm.warp(block.timestamp + PERIOD);
        assertGt(v.claimable(alice), 0, "she earns from the moment she is back in");
    }

    function test_laterOptInDoesNotSweepAnIdleFreeze() public {
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        assertEq(v.vested(), 0, "the idle window does not project a vest");
        uint256 pot = v.remaining();
        assertEq(pot, PREMIUM, "so remaining is the stored pot");

        _stake(alice, 100e18);
        assertEq(v.claimable(alice), 0, "she missed the idle window");
        assertEq(v.remaining(), pot, "the buffer is still held");
        assertEq(v.vested(), 0);

        vm.warp(block.timestamp + PERIOD);
        assertApproxEqRel(v.claimable(alice), pot * 632 / 1000, 0.02e18, "and only then starts to vest");
        assertApproxEqAbs(v.claimable(alice), v.vested(), 1, "the sole earner is owed the unwritten vest");
        assertEq(v.remaining() + v.vested(), pot);

        uint256 projected = v.claimable(alice);
        vm.prank(alice);
        assertEq(v.claim(alice), projected, "settlement matches the view");
        assertEq(v.vested(), 0, "the write consumed the projection");
        assertEq(v.remaining(), v.remainder());
    }

    function test_transferBetweenNonOptedHoldersDoesNotMoveTheClock() public {
        address carol = makeAddr("carol");
        _stake(alice, 100e18);
        v.mint(bob, 50e18);
        v.mint(carol, 50e18);

        vm.warp(block.timestamp + PERIOD);
        uint256 last = v.lastUpdate();

        vm.prank(bob);
        assertTrue(v.transfer(carol, 10e18));

        assertEq(v.lastUpdate(), last, "no earner moved, so the vest is not written");
        assertEq(v.stakedSupply(), 100e18);
        assertEq(v.balanceOf(bob), 40e18);
        assertEq(v.balanceOf(carol), 60e18);
    }

    function test_transferToANonOptedHolderDropsStakedAndPaysThemNothing() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);

        vm.prank(alice);
        assertTrue(v.transfer(bob, 40e18));

        assertEq(v.stakedSupply(), 60e18);
        assertFalse(v.optedIn(bob));
        assertEq(v.claimable(bob), 0);

        vm.warp(block.timestamp + _untilSettled());
        assertEq(v.claimable(bob), 0, "a holder that never opted in earns none of it");
        assertApproxEqRel(v.claimable(alice), PREMIUM, 1e12, "the opted-in remainder takes the pot");
    }

    function test_transferToAnOptedInHolderKeepsStakedInStep() public {
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        assertEq(v.stakedSupply(), 100e18);

        vm.prank(alice);
        assertTrue(v.transfer(bob, 25e18));

        assertEq(v.stakedSupply(), 100e18);
        assertEq(v.balanceOf(alice), 50e18);
        assertEq(v.balanceOf(bob), 50e18);

        _fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());
        assertApproxEqRel(v.claimable(alice), PREMIUM / 2, 1e12);
        assertApproxEqRel(v.claimable(bob), PREMIUM / 2, 1e12);
    }

    function test_selfTransferDoesNotChangeStakedOrEntitlement() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);
        uint256 owed = v.claimable(alice);

        vm.prank(alice);
        assertTrue(v.transfer(alice, 40e18));

        assertEq(v.stakedSupply(), 100e18);
        assertEq(v.balanceOf(alice), 100e18);
        assertApproxEqAbs(v.claimable(alice), owed, 1);
    }

    function test_burnFromAnOptedInHolderDropsStaked() public {
        _stake(alice, 100e18);
        v.burn(alice, 30e18);
        assertEq(v.stakedSupply(), 70e18);
        assertEq(v.balanceOf(alice), 70e18);
    }

    function test_transferToTheVaultDropsStaked() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        assertTrue(v.transfer(address(v), 100e18));
        assertEq(v.stakedSupply(), 0);
        assertFalse(v.optedIn(address(v)));
    }

    function test_claimPaysTheCallerAndClearsTheEntitlement() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());

        uint256 owed = v.claimable(alice);
        vm.expectEmit(true, true, false, false);
        emit IPremiumVesting.Claimed(alice, alice, owed);
        vm.prank(alice);
        uint256 paid = v.claim(alice);

        assertApproxEqAbs(paid, owed, 1);
        assertEq(v.claimable(alice), 0);
        assertEq(v.claim(alice), 0, "it cannot be drawn twice");
        assertEq(premium.balanceOf(alice), paid);
    }

    function test_claimCanPayADifferentRecipient() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());

        vm.prank(alice);
        uint256 paid = v.claim(bob);
        assertGt(paid, 0);
        assertEq(premium.balanceOf(bob), paid);
        assertEq(premium.balanceOf(alice), 0);
    }

    function test_claimableViewAgreesWithClaimWithoutAPriorWrite() public {
        _stake(alice, 100e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);

        uint256 projected = v.claimable(alice);
        assertGt(projected, 0, "the view projects unwritten vest");
        vm.prank(alice);
        assertEq(v.claim(alice), projected);
    }

    function test_claimClampsToWhatTheVaultActuallyHolds() public {
        _stake(alice, 100e18);
        v.fund(PREMIUM);
        premium.mint(address(v), 1);
        vm.warp(block.timestamp + _untilSettled());

        assertGt(v.claimable(alice), 1, "she is owed more than is sitting here");
        vm.prank(alice);
        assertEq(v.claim(alice), 1, "but she is paid what is there");
    }

    function test_twoHoldersSplitByOptedInBalance() public {
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        _fund(PREMIUM);
        vm.warp(block.timestamp + _untilSettled());

        uint256 toAlice = v.claimable(alice);
        uint256 toBob = v.claimable(bob);
        assertApproxEqRel(toAlice, PREMIUM * 3 / 4, 1e12);
        assertApproxEqRel(toBob, PREMIUM / 4, 1e12);
        assertLe(toAlice + toBob, PREMIUM);
    }
}
