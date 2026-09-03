// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { WadRayMath } from "./WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PremiumVesting
/// @author kexley, Cap Labs
/// @notice Linear premium vesting with per-share distribution, shared by {Tranche} and {Underwriter}.
///
/// A schedule holds a lump of premium and releases it evenly across an epoch. Whatever comes due is
/// divided by the supply staked at that moment and added to a cumulative per-share figure, so a
/// holder's entitlement is `perShare × balance` net of a checkpoint taken whenever their balance
/// moved. Topping the schedule up or repointing it at a new period restarts the epoch carrying
/// whatever was still locked, so premium is never dropped and never released early.
///
/// The per-share accumulator is part of this library rather than left to the caller because
/// {accrue} is the only thing that writes it. Splitting the two would put the epoch on one side of
/// the boundary and the division that consumes it on the other.
///
/// Callers own the supply figure and pass it in, since what counts as staked is theirs to define —
/// both of ours use `activeSupply`, which excludes shares queued for redemption.
///
/// The one precondition is that `period` is never zero, because every release divides by it. Both
/// callers hardcode it at initialization and reject zero in their setters.
library PremiumVesting {
    using WadRayMath for uint256;

    /// @param period The epoch length in seconds
    /// @param start The epoch anchor. Set to now when the epoch restarts, then slid forward by any
    /// window in which nothing was staked, so it is not necessarily when premium last arrived
    /// @param vested The premium being released across the epoch
    /// @param lastUpdate The point accrual has been settled up to, never beyond the epoch end
    /// @param perShare The cumulative premium released per staked share, in ray decimals
    /// @param pending Premium credited to an account and awaiting collection
    /// @param debt Premium already accounted to an account at its last balance checkpoint
    struct Schedule {
        uint256 period;
        uint256 start;
        uint256 vested;
        uint256 lastUpdate;
        uint256 perShare;
        mapping(address account => uint256 amount) pending;
        mapping(address account => uint256 amount) debt;
    }

    /// @dev Open an empty schedule anchored at now.
    ///
    /// Anchoring matters even with nothing to release. Left at zero, `start` would put the epoch at
    /// the unix epoch, and the first {accrue} would slide it forward by fifty-odd years or park the
    /// cursor at a timestamp in the past. Both are harmless while `vested` is zero, and both make
    /// every reader of {end} or {locked} wrong until premium first arrives.
    /// @param s The schedule to open
    /// @param period The epoch length in seconds, which must not be zero
    function open(Schedule storage s, uint256 period) internal {
        s.period = period;
        s.start = block.timestamp;
        s.lastUpdate = block.timestamp;
    }

    /// @dev Release whatever premium has come due to the supply that was staked for it.
    ///
    /// While nothing is staked the epoch slides forward by the idle time rather than the clock
    /// being frozen. Freezing preserves the premium only as a cliff: the moment supply returns the
    /// whole idle window releases against whatever is there, so a one wei deposit sweeps the buffer
    /// having borne no risk for a second of it. Sliding keeps every wei and still drips it over the
    /// time the epoch had left, so premium only reaches capital that was exposed while it vested.
    ///
    /// Sliding also leaves {locked} equal to the un-released remainder rather than only the
    /// not-yet-due part, which is the figure {fund} and {setPeriod} carry across. Under a frozen
    /// clock they read back less than was actually held and stranded the difference for good.
    /// @param s The schedule to accrue
    /// @param supply The shares staked as of now
    function accrue(Schedule storage s, uint256 supply) internal {
        uint256 until = Math.min(block.timestamp, s.start + s.period);
        if (until <= s.lastUpdate) return;

        if (supply == 0) {
            // slid by the elapsed time rather than to `until`, so an epoch that has already ended
            // still moves whole and the remaining fraction {locked} reports is untouched
            s.start += block.timestamp - s.lastUpdate;
            s.lastUpdate = block.timestamp;
            return;
        }

        uint256 amount = unlocked(s);
        if (amount > 0) s.perShare += amount.rayDiv(supply);
        s.lastUpdate = until;
    }

    /// @dev Add premium and restart the epoch over the current period, carrying anything locked
    /// @param s The schedule to fund
    /// @param amount The premium to add
    function fund(Schedule storage s, uint256 amount) internal {
        _restart(s, locked(s) + amount, s.period);
    }

    /// @dev Restart the epoch over a new period, carrying anything locked. Shortening a period can
    /// put the new end behind the old one, which is why {accrue} clamps rather than assuming the
    /// end only ever moves forward.
    /// @param s The schedule to repoint
    /// @param period The new epoch length in seconds
    function setPeriod(Schedule storage s, uint256 period) internal {
        _restart(s, locked(s), period);
    }

    /// @dev Move an account's checkpoint across a balance change, banking what it has earned so far
    /// @param s The schedule to checkpoint against
    /// @param account The account whose balance is moving
    /// @param balance The balance the account holds now
    /// @param newBalance The balance the account will hold
    function checkpoint(Schedule storage s, address account, uint256 balance, uint256 newBalance) internal {
        uint256 perShare = s.perShare;
        s.pending[account] += perShare.rayMul(balance) - s.debt[account];
        s.debt[account] = perShare.rayMul(newBalance);
    }

    /// @dev Zero an account's entitlement and hand it back for payment.
    ///
    /// Reads the settled `perShare` rather than the projection {claimable} uses, so the caller must
    /// {accrue} first. After an accrual the two agree, since anything the projection would add has
    /// been written.
    /// @param s The schedule to settle against
    /// @param account The account being paid
    /// @param balance The account's share balance
    /// @return premium The premium owed to the account
    function settle(Schedule storage s, address account, uint256 balance) internal returns (uint256 premium) {
        uint256 perShare = s.perShare;
        premium = s.pending[account] + perShare.rayMul(balance) - s.debt[account];
        if (premium > 0) {
            s.pending[account] = 0;
            s.debt[account] = perShare.rayMul(balance);
        }
    }

    /// @dev The premium an account could collect, including accrual not yet written to storage
    /// @param s The schedule to read
    /// @param account The account to query
    /// @param balance The account's share balance
    /// @param supply The shares staked as of now
    /// @return premium The premium owed to the account
    function claimable(Schedule storage s, address account, uint256 balance, uint256 supply)
        internal
        view
        returns (uint256 premium)
    {
        premium = s.pending[account] + projectedPerShare(s, supply).rayMul(balance) - s.debt[account];
    }

    /// @dev The per-share figure including accrual not yet written to storage
    /// @param s The schedule to read
    /// @param supply The shares staked as of now
    /// @return perShare The projected premium per share in ray decimals
    function projectedPerShare(Schedule storage s, uint256 supply) internal view returns (uint256 perShare) {
        perShare = s.perShare;
        if (supply > 0) {
            uint256 amount = unlocked(s);
            if (amount > 0) perShare += amount.rayDiv(supply);
        }
    }

    /// @dev The premium that has come due since the last accrual
    /// @param s The schedule to read
    /// @return amount The premium awaiting release
    function unlocked(Schedule storage s) internal view returns (uint256 amount) {
        uint256 until = Math.min(block.timestamp, s.start + s.period);
        if (until <= s.lastUpdate) return 0;
        amount = s.vested * (until - s.lastUpdate) / s.period;
    }

    /// @dev The premium still held back by the epoch.
    ///
    /// Written against the epoch end rather than as `period - (now - start)` so it cannot
    /// underflow, and so it stays correct across the slide in {accrue}, which moves `start` past
    /// the point premium last arrived.
    ///
    /// Reads settled state, so an idle window that has not been accrued yet reads as zero once the
    /// epoch end has passed, when the truth is that the whole remainder is still held. It cannot
    /// project its way out of that: the pending accrual either releases or slides depending on the
    /// supply, and the supply is the caller's to know. {fund} and {setPeriod} are unaffected
    /// because both callers accrue first, which is what turns that remainder into a real reading.
    /// @param s The schedule to read
    /// @return amount The premium not yet released
    function locked(Schedule storage s) internal view returns (uint256 amount) {
        uint256 finish = s.start + s.period;
        if (block.timestamp >= finish) return 0;
        amount = s.vested * (finish - block.timestamp) / s.period;
    }

    /// @dev The point the epoch releases its last premium
    /// @param s The schedule to read
    /// @return timestamp The epoch end
    function end(Schedule storage s) internal view returns (uint256 timestamp) {
        timestamp = s.start + s.period;
    }

    /// @dev The nominal release rate. Reported for callers that expose it, and not used to accrue:
    /// {unlocked} scales the lump by elapsed time instead, which avoids truncating the rate and
    /// then multiplying the error back up.
    /// @param s The schedule to read
    /// @return perSecond The premium released per second
    function rate(Schedule storage s) internal view returns (uint256 perSecond) {
        perSecond = s.vested / s.period;
    }

    /// @dev Restart the epoch now, releasing `total` across `period`
    function _restart(Schedule storage s, uint256 total, uint256 period) private {
        s.period = period;
        s.vested = total;
        s.start = block.timestamp;
        s.lastUpdate = block.timestamp;
    }
}
