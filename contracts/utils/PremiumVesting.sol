// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC7540AsyncRedeem } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IPremiumVesting } from "../interfaces/IPremiumVesting.sol";
import { DeadShares } from "./DeadShares.sol";
import { WadRayMath } from "./WadRayMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PremiumVesting
/// @author kexley, Cap Labs
/// @notice Exponential premium vesting over a 12-hour time constant
/// @dev Only opted-in balances earn. Zero staked supply freezes the remainder.
abstract contract PremiumVesting is IPremiumVesting, ERC7540AsyncRedeem {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    /// @notice Emitted when premium is added to the remainder
    /// @param amount The premium added, in stablecoin units (18 decimals)
    event Fund(uint256 amount);

    /// @dev Per-share conversions floor. A floored debt can still let entitlements sum past the
    /// pot; {claim} pays at most the stablecoin this contract holds.
    uint256 private constant RAY = WadRayMath.RAY;

    /// @notice Twelve-hour time constant. After a day most of a pot has vested
    uint256 public constant VESTING_PERIOD = 12 hours;

    /// @custom:storage-location cap.storage.PremiumVesting
    /// @param remainder Premium still held
    /// @param lastUpdate The point accrual has been settled up to
    /// @param perShare Cumulative premium released per staked share, in ray decimals
    /// @param pending Premium credited to an account and awaiting collection
    /// @param debt Premium already accounted to an account at its last balance checkpoint
    /// @param stablecoin The token premium is paid in
    /// @param optedIn Whether an account earns
    /// @param staked Sum of opted-in balances
    struct PremiumVestingStorage {
        uint256 remainder;
        uint256 lastUpdate;
        uint256 perShare;
        mapping(address account => uint256 amount) pending;
        mapping(address account => uint256 amount) debt;
        address stablecoin;
        mapping(address account => bool opted) optedIn;
        uint256 staked;
    }

    // keccak256(abi.encode(uint256(keccak256("cap.storage.PremiumVesting")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev ERC-7201 storage slot for PremiumVesting
    bytes32 private constant PREMIUM_VESTING_STORAGE_LOCATION =
        0xcd5f59be90fcb6cd1e07c030ed45d88d80c86b8efb27e0d1fc4732fdedcd1c00;

    /// @dev Accrue vested premium into per-share before the wrapped call
    modifier updatePremium() {
        _updatePremium();
        _;
    }

    /// @inheritdoc IPremiumVesting
    function vestingPeriod() public pure returns (uint256 period) {
        period = VESTING_PERIOD;
    }

    /// @inheritdoc IPremiumVesting
    function vested() public view returns (uint256 amount) {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        amount = _vested($, $.staked);
    }

    /// @inheritdoc IPremiumVesting
    function remaining() public view returns (uint256 amount) {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        amount = $.remainder - _vested($, $.staked);
    }

    /// @inheritdoc IPremiumVesting
    function premiumPerSecond() public view returns (uint256 perSecond) {
        perSecond = remaining() / VESTING_PERIOD;
    }

    /// @inheritdoc IPremiumVesting
    function lastPremiumUpdate() public view returns (uint256 timestamp) {
        timestamp = _getPremiumVestingStorage().lastUpdate;
    }

    /// @inheritdoc IPremiumVesting
    function premiumPerShare() public view returns (uint256 perShare) {
        perShare = _getPremiumVestingStorage().perShare;
    }

    /// @inheritdoc IPremiumVesting
    function pendingPremium(address user) public view returns (uint256 premium) {
        premium = _getPremiumVestingStorage().pending[user];
    }

    /// @inheritdoc IPremiumVesting
    function claimable(address user) public view returns (uint256 premium) {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        uint256 earning = $.optedIn[user] ? balanceOf(user) : 0;
        premium = _claimable($, user, earning, $.staked);
    }

    /// @inheritdoc IPremiumVesting
    function stakedSupply() public view returns (uint256 supply) {
        supply = _getPremiumVestingStorage().staked;
    }

    /// @inheritdoc IPremiumVesting
    function optedIn(address account) public view returns (bool opted) {
        opted = _getPremiumVestingStorage().optedIn[account];
    }

    /// @inheritdoc IPremiumVesting
    function optIn() public updatePremium {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        if ($.optedIn[msg.sender] || msg.sender == address(this) || msg.sender == DeadShares.HOLDER) return;
        uint256 bal = balanceOf(msg.sender);
        // start from the current per-share so the window before this call is not theirs
        $.debt[msg.sender] = _owed($.perShare, bal);
        $.optedIn[msg.sender] = true;
        $.staked += bal;
        emit OptIn(msg.sender);
    }

    /// @inheritdoc IPremiumVesting
    function optOut() public updatePremium {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        if (!$.optedIn[msg.sender]) return;
        uint256 bal = balanceOf(msg.sender);
        _checkpoint($, msg.sender, bal, 0);
        $.optedIn[msg.sender] = false;
        $.staked -= bal;
        emit OptOut(msg.sender);
    }

    /// @inheritdoc IPremiumVesting
    function stablecoin() public view returns (address token) {
        token = _getPremiumVestingStorage().stablecoin;
    }

    /// @inheritdoc IPremiumVesting
    function claim(address recipient) public returns (uint256 premium) {
        premium = _settlePremium(msg.sender);
        // the per-share arithmetic floors in both directions, so the ordinary case under-pays and
        // the remainder stays here. The clamp is still load-bearing: a debt rounded down can let
        // entitlements sum past the pot, and without it the last holder out hits a failed transfer.
        // Pay what is spendable; a vault may reserve some of the raw balance (cUSD escrow).
        uint256 available = _spendablePremium();
        if (premium > available) premium = available;
        if (premium == 0) return 0;

        IERC20(stablecoin()).safeTransfer(recipient, premium);
        emit Claimed(msg.sender, recipient, premium);
    }

    /// @dev Premium token this contract may pay out. Default is the raw balance; cUSD subtracts
    /// the redemption queue so escrowed shares are not paid as yield.
    /// @return available Spendable premium-token units
    function _spendablePremium() internal view virtual returns (uint256 available) {
        available = IERC20(stablecoin()).balanceOf(address(this));
    }

    /// @dev Initialize the ERC7540 vault
    /// @param asset The vault asset
    /// @param name The token name
    /// @param symbol The token symbol
    /// @param token The stablecoin premium is paid in
    // forge-lint: disable-next-item(mixed-case-function)
    function __PremiumVesting_init(IERC20 asset, string memory name, string memory symbol, address token)
        internal
        onlyInitializing
    {
        __ERC7540AsyncRedeem_init(asset, name, symbol);
        _getPremiumVestingStorage().stablecoin = token;
    }

    /// @dev Credit whatever has vested since the last accrual to the current supply
    function _updatePremium() internal {
        _accrue(_getPremiumVestingStorage(), stakedSupply());
    }

    /// @dev Add premium to the remainder and update the rate
    /// @param premium The premium being folded in
    function _fund(uint256 premium) internal updatePremium {
        _getPremiumVestingStorage().remainder += premium;
        emit Fund(premium);
    }

    /// @dev Record the claimable premium for an account. Caller must {_updatePremium} first.
    /// @param account The account collecting
    /// @return premium The entitlement just cleared
    function _settlePremium(address account) internal updatePremium returns (uint256 premium) {
        PremiumVestingStorage storage $ = _getPremiumVestingStorage();
        // a holder that is out still collects what was banked on the way out, but their live
        // balance is not earning and must not be valued against perShare
        uint256 earning = $.optedIn[account] ? balanceOf(account) : 0;
        premium = _settle($, account, earning);
    }

    /// @dev Accrue, checkpoint, and keep the opted-in supply in step before the share balances move
    /// @dev Transfers between two non-opted accounts skip the vest write when someone is already
    /// earning; an idle pot still freezes so {remaining} does not drift.
    /// @param from The sender, or zero on mint
    /// @param to The recipient, or zero on burn
    /// @param amount The shares moving
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != to) {
            PremiumVestingStorage storage $ = _getPremiumVestingStorage();
            bool fromIn = $.optedIn[from];
            bool toIn = $.optedIn[to];
            if (fromIn || toIn || $.staked == 0) _accrue($, $.staked);
            if (fromIn) {
                uint256 balance = balanceOf(from);
                _checkpoint($, from, balance, balance - amount);
                $.staked -= amount;
            }
            if (toIn) {
                uint256 balance = balanceOf(to);
                _checkpoint($, to, balance, balance + amount);
                $.staked += amount;
            }
        }
        super._update(from, to, amount);
    }

    /// @dev Get the ERC-7201 namespaced storage pointer
    /// @return $ The PremiumVesting storage
    function _getPremiumVestingStorage() internal pure returns (PremiumVestingStorage storage $) {
        bytes32 slot = PREMIUM_VESTING_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    /// @dev Credit vested premium to `supply` and take it off the remainder. Zero supply freezes.
    /// @param $ The PremiumVesting storage
    /// @param supply The shares that earn, against which the vest is divided
    function _accrue(PremiumVestingStorage storage $, uint256 supply) internal {
        if (block.timestamp <= $.lastUpdate) return;

        if (supply == 0) {
            $.lastUpdate = block.timestamp;
            return;
        }

        uint256 amount = _vested($, supply);
        if (amount > 0) {
            $.perShare += Math.mulDiv(amount, RAY, supply, Math.Rounding.Floor);
            $.remainder -= amount;
        }
        $.lastUpdate = block.timestamp;
    }

    /// @dev Bank what an account has earned before its balance moves
    /// @param $ The PremiumVesting storage
    /// @param account The account whose balance is about to change
    /// @param balance The share balance before the move
    /// @param newBalance The share balance after the move
    function _checkpoint(PremiumVestingStorage storage $, address account, uint256 balance, uint256 newBalance)
        internal
    {
        uint256 perShare = $.perShare;
        $.pending[account] += _owed(perShare, balance) - $.debt[account];
        $.debt[account] = _owed(perShare, newBalance);
    }

    /// @dev Zero an account's entitlement and hand it back
    /// @param $ The PremiumVesting storage
    /// @param account The account collecting
    /// @param balance The account's current share balance
    /// @return premium The entitlement just cleared
    function _settle(PremiumVestingStorage storage $, address account, uint256 balance)
        internal
        returns (uint256 premium)
    {
        uint256 perShare = $.perShare;
        premium = $.pending[account] + _owed(perShare, balance) - $.debt[account];
        if (premium > 0) {
            $.pending[account] = 0;
            $.debt[account] = _owed(perShare, balance);
        }
    }

    /// @dev Premium an account could collect, including vest not yet written
    /// @param $ The PremiumVesting storage
    /// @param account The account to query
    /// @param balance The account's current share balance
    /// @param supply The shares that earn, used to project unwritten vest
    /// @return premium Pending plus unwritten vest, less already-accounted debt
    function _claimable(PremiumVestingStorage storage $, address account, uint256 balance, uint256 supply)
        internal
        view
        returns (uint256 premium)
    {
        premium = $.pending[account] + _owed(_projectedPerShare($, supply), balance) - $.debt[account];
    }

    /// @dev `perShare` plus the vest not yet written
    /// @param $ The PremiumVesting storage
    /// @param supply The shares that earn. Zero skips the projection, matching a freeze
    /// @return perShare Settled per-share plus the unwritten vest, in ray decimals
    function _projectedPerShare(PremiumVestingStorage storage $, uint256 supply)
        internal
        view
        returns (uint256 perShare)
    {
        perShare = $.perShare;
        if (supply > 0) {
            uint256 amount = _vested($, supply);
            if (amount > 0) perShare += Math.mulDiv(amount, RAY, supply, Math.Rounding.Floor);
        }
    }

    /// @dev Premium newly available since `lastUpdate` against `supply`. Zero supply
    /// matches an {_accrue} freeze: nothing is released and the pot does not age.
    /// @param $ The PremiumVesting storage
    /// @param supply The shares that earn
    /// @return amount Premium newly available since `lastUpdate`, in stablecoin units (18 decimals)
    function _vested(PremiumVestingStorage storage $, uint256 supply) internal view returns (uint256 amount) {
        if (supply == 0) return 0;
        if (block.timestamp <= $.lastUpdate) return 0;
        uint256 weight = _weight(block.timestamp - $.lastUpdate);
        if (weight == 0) return 0;
        amount = Math.mulDiv($.remainder, weight, RAY, Math.Rounding.Floor);
    }

    /// @dev Premium attributed to `balance` at `perShare`. Floors per account. Aggregate
    /// entitlements can still exceed the pot when a prior debt also floored; {claim} caps payout
    /// at the stablecoin held.
    /// @param perShare Cumulative premium released per staked share, in ray decimals
    /// @param balance The share balance being valued
    /// @return amount The attributed premium, in stablecoin units (18 decimals)
    function _owed(uint256 perShare, uint256 balance) private pure returns (uint256 amount) {
        amount = Math.mulDiv(perShare, balance, RAY, Math.Rounding.Floor);
    }

    /// @dev `1 - retention^elapsed`. Splits of the interval compose, subject to fixed-point rounding.
    /// @param elapsed Seconds since the last accrual
    /// @return weight Fraction of the remainder that has vested, in ray decimals
    function _weight(uint256 elapsed) private pure returns (uint256 weight) {
        uint256 retention = RAY - RAY / VESTING_PERIOD;
        weight = RAY - retention.rayPow(elapsed);
    }
}
