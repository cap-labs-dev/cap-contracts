// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley, Cap Labs
/// @notice Curator vault that allocates assets into tranches and distributes premium to depositors.
contract Underwriter layout at erc7201("cap.storage.Underwriter")
    is
    IUnderwriter,
    IERC1155Receiver,
    AccessManagedUpgradeable,
    ERC7540AsyncRedeem
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using PremiumVesting for PremiumVesting.Schedule;

    /// @inheritdoc IUnderwriter
    address public vault;

    /// @inheritdoc IUnderwriter
    address public stablecoin;

    /// @dev The premium vesting schedule and its per-share distribution accounting
    PremiumVesting.Schedule private _premium;

    /// @inheritdoc IUnderwriter
    address public defaultTranche;

    /// @inheritdoc IUnderwriter
    mapping(address => uint256) public debt;

    /// @inheritdoc IUnderwriter
    uint256 public totalDebt;

    /// @dev The list of registered tranches
    EnumerableSet.AddressSet private _registeredTranches;

    /// @inheritdoc IUnderwriter
    mapping(address => uint256) public queuedShares;

    /// @inheritdoc IUnderwriter
    mapping(address => mapping(uint256 => uint256)) public queuedRequest;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IUnderwriter
    function initialize(
        address _authority,
        string memory _name,
        string memory _symbol,
        address _asset,
        address _vaultAddress,
        address _stablecoinAddress
    ) external override initializer {
        __AccessManaged_init(_authority);
        __ERC7540AsyncRedeem_init(IERC20(_asset), _name, _symbol, hex"");
        vault = _vaultAddress;
        stablecoin = _stablecoinAddress;
        _premium.open(6 hours);
    }

    /// @inheritdoc IUnderwriter
    function addTranche(address _tranche) external restricted {
        _registeredTranches.add(_tranche);
        // the tranche pulls this contract's vault balance on deposit, so it needs operator rights
        // for as long as it is registered and no longer
        IVault(vault).setOperator(_tranche, true);
        emit AddTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function removeTranche(address _tranche) external restricted {
        _registeredTranches.remove(_tranche);
        IVault(vault).setOperator(_tranche, false);
        // every deposit routes through {_transferIn} into {_allocate}, which insists on
        // registration, so a deregistered tranche left as the default would revert each one.
        // Clearing it holds incoming assets in the vault instead, which is what an unset default
        // already means, and the curator can point it somewhere live at their leisure
        if (defaultTranche == _tranche) {
            defaultTranche = address(0);
            emit SetDefaultTranche(address(0));
        }
        emit RemoveTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function allocate(address tranche, uint256 assets) external restricted {
        _allocate(tranche, assets);
    }

    /// @dev Allocate assets to a tranche
    function _allocate(address tranche, uint256 assets) internal {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        ITranche(tranche).deposit(assets, address(this));
        _mark(tranche);
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares) external restricted returns (uint256 deallocated) {
        // clamped by this contract's own holding as well as the tranche's unlocked supply, so an
        // oversized request comes back as a short fill the way {deallocateAsync} does rather than
        // reverting inside the tranche's burn
        uint256 available =
            Math.min(ITranche(tranche).balanceOf(address(this)), ITranche(tranche).instantUnlockedSupply());
        deallocated = Math.min(shares, available);
        if (deallocated > 0) IERC4626(tranche).redeem(deallocated, address(this), address(this));
        // outside the branch, so the postcondition is simply that this tranche's mark is fresh when
        // the call returns, whether or not there was anything to pull out
        _mark(tranche);
    }

    /// @inheritdoc IUnderwriter
    function deallocateAsync(address tranche, uint256 shares) external restricted returns (uint256 requestId) {
        uint256 balance = ITranche(tranche).balanceOf(address(this));
        if (shares > balance) shares = balance;

        requestId = ITranche(tranche).requestRedeem(shares, address(this), address(this));

        // the request itself gives nothing up, so these two only move the position from one column
        // to the other: the shares have left this contract's balance for the tranche's own, and
        // this is what keeps {_mark} able to see them while they sit there
        queuedShares[tranche] += shares;
        queuedRequest[tranche][requestId] = shares;

        _mark(tranche);

        emit RequestedRedeem(tranche, shares, requestId);
    }

    /// @inheritdoc IUnderwriter
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares) external restricted {
        // a request is only settled down against what this contract queued under that id. Anyone
        // can name this vault as the controller of a redemption they request against their own
        // shares, which mints a receipt here that no allocation of ours backs. Settling one of
        // those against the aggregate would retire shares still genuinely queued and take the mark
        // back below the position, so an unrecognised id is refused and the gift simply ignored.
        uint256 recorded = queuedRequest[tranche][requestId];
        if (shares > recorded) revert UnknownQueuedRequest();

        ITranche(tranche).redeem(requestId, shares, address(this), address(this));

        queuedRequest[tranche][requestId] = recorded - shares;
        queuedShares[tranche] -= shares;

        _mark(tranche);
    }

    /// @dev Re-value this contract's position in a tranche and carry the difference into
    /// `totalDebt`. Every path that moves a position ends here, so the cached valuation is refreshed
    /// whenever the underwriter touches a tranche rather than only when the curator reports.
    ///
    /// Writing the position down by whatever came back from a redemption is not enough, and was the
    /// bug this replaces. A slashed tranche returns less than was allocated, so the shortfall stayed
    /// on the books as debt against a position that had already been exited, and the same call
    /// released the idle assets that made that phantom extractable. Deriving the mark from the
    /// remaining shares instead means a full exit always leaves nothing recorded.
    ///
    /// Nothing the tranche returns is trusted here: the mark is read from the position rather than
    /// from a withdrawal figure, so `totalDebt` cannot be driven negative by a tranche that ever
    /// paid out more than it took in. It stays the exact sum of every `debt` entry.
    ///
    /// The position is not the balance alone. {IERC7540AsyncRedeem-requestRedeem} moves the shares
    /// to the tranche and hands back a receipt, so a queued deallocation would read as a position
    /// wiped out while its assets are still in flight — and a depositor arriving in that window
    /// would mint against a valuation of nearly nothing and capture the rebound on settlement.
    /// `queuedShares` carries them until they settle. Both parts price at the same live figure:
    /// queued shares stay in the tranche's supply against assets that stay in the tranche until the
    /// burn, and {IERC7540AsyncRedeem-redeem} pays out at the price on the day it is claimed, so a
    /// slash landing mid-queue is felt here exactly as it would be on shares still held.
    /// @param tranche The tranche to re-value
    /// @return gain The increase in the recorded position, if any
    /// @return loss The decrease in the recorded position, if any
    function _mark(address tranche) internal returns (uint256 gain, uint256 loss) {
        uint256 recorded = debt[tranche];
        uint256 position = ITranche(tranche).balanceOf(address(this)) + queuedShares[tranche];
        uint256 assets = ITranche(tranche).previewRedeem(position);
        if (assets == recorded) return (0, 0);

        if (assets < recorded) {
            loss = recorded - assets;
            totalDebt -= loss;
            emit DebtDecreased(tranche, loss);
        } else {
            gain = assets - recorded;
            totalDebt += gain;
            emit DebtIncreased(tranche, gain);
        }
        debt[tranche] = assets;
    }

    /// @inheritdoc IUnderwriter
    function setDefaultTranche(address tranche) external restricted {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        defaultTranche = tranche;
        emit SetDefaultTranche(tranche);
    }

    /// @inheritdoc IUnderwriter
    /// @dev Accrue under the outgoing schedule first, then re-vest whatever is still locked over
    /// the new period, matching {Tranche.setVestingPeriod}.
    function setVestingPeriod(uint256 _vestingPeriod) external restricted {
        if (_vestingPeriod == 0) revert InvalidVestingPeriod();
        _updatePremiums();
        _premium.setPeriod(_vestingPeriod);
        emit SetVestingPeriod(_vestingPeriod);
    }

    /// @inheritdoc IUnderwriter
    function report(address _tranche) external restricted {
        if (!_registeredTranches.contains(_tranche)) revert NotRegisteredTranche();
        (uint256 gain, uint256 loss) = _mark(_tranche);

        // settle any premiums accrued under the previous schedule before re-vesting
        _updatePremiums();

        uint256 premium = ITranche(_tranche).claim(address(this));
        _premium.fund(premium);

        emit Reported(_tranche, premium, gain, loss);
    }

    /// @inheritdoc IUnderwriter
    function claim() external returns (uint256 premium) {
        _updatePremiums();
        premium = _premium.settle(msg.sender, balanceOf(msg.sender));
        // clamped for the same rounding reason as {Tranche-claim}, against the balance directly
        // since every stablecoin this holds is premium swept from {report}. Unclamped the overrun
        // surfaces as a failed transfer rather than an underflow, but it strands the claim either
        // way
        uint256 held = IERC20(stablecoin).balanceOf(address(this));
        if (premium > held) premium = held;
        if (premium == 0) return 0;
        IERC20(stablecoin).safeTransfer(msg.sender, premium);
        emit Claimed(msg.sender, premium);
    }

    /// @inheritdoc IUnderwriter
    function claimable(address user) external view returns (uint256 premium) {
        // gated the same way as {Tranche-claimable}; see there for why the burn address reads zero
        if (user == DeadShares.HOLDER) return 0;
        premium = _premium.claimable(user, balanceOf(user), stakedSupply());
    }

    /// @inheritdoc IUnderwriter
    function vestingPeriod() external view returns (uint256 period) {
        period = _premium.period;
    }

    /// @inheritdoc IUnderwriter
    function lastReported() external view returns (uint256 timestamp) {
        timestamp = _premium.start;
    }

    /// @inheritdoc IUnderwriter
    function vestedPremium() external view returns (uint256 premium) {
        premium = _premium.vested;
    }

    /// @inheritdoc IUnderwriter
    function premiumPerSecond() external view returns (uint256 perSecond) {
        perSecond = _premium.rate();
    }

    /// @inheritdoc IUnderwriter
    function lastPremiumUpdate() external view returns (uint256 timestamp) {
        timestamp = _premium.lastUpdate;
    }

    /// @inheritdoc IUnderwriter
    function premiumPerShare() external view returns (uint256 perShare) {
        perShare = _premium.perShare;
    }

    /// @inheritdoc IUnderwriter
    function pendingPremium(address user) external view returns (uint256 premium) {
        premium = _premium.pending[user];
    }

    /// @inheritdoc IUnderwriter
    function vestedReward() public view returns (uint256 vested) {
        vested = _premium.locked();
    }

    /// @inheritdoc IUnderwriter
    function vestingEnd() public view returns (uint256 end) {
        end = _premium.end();
    }

    /// @inheritdoc IERC4626
    /// @dev The caller must hold whichever role the AccessManager has assigned to this selector on
    /// this vault. Membership of that role is the allowlist, and no second copy of it is stored
    /// here, so admitting a depositor means granting them the role. The curator can do that,
    /// because the Registry made their operator role its admin.
    ///
    /// Pointing the selector at a different role, including the public role to open the vault to
    /// everyone, is a {IAccessManager-setTargetFunctionRole} call, which is reserved to ADMIN.
    ///
    /// This modifier is the whole gate: the receiver is unrestricted and {maxDeposit} is left at
    /// the ERC4626 default. Gating the receiver as well would contradict it, because a member
    /// granted the role under an execution delay clears this modifier by consuming a scheduled
    /// operation while still reading as unauthorized through {IAccessManager-canCall}'s immediate
    /// flag. It would also be a gate on the wrong subject, and one worth little, since shares are
    /// transferable as soon as they are minted.
    function deposit(uint256 _assets, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        restricted
        returns (uint256 shares)
    {
        shares = super.deposit(_assets, _receiver);
    }

    /// @inheritdoc IERC4626
    /// @dev Gated the same way as {deposit}; see there for how the allowlist works
    function mint(uint256 _shares, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        restricted
        returns (uint256 assets)
    {
        assets = super.mint(_shares, _receiver);
    }

    /// @inheritdoc IUnderwriter
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IUnderwriter) returns (uint256) {
        return IVault(vault).balanceOf(address(this), asset()) + totalDebt;
    }

    /// @inheritdoc IERC4626
    /// @dev While the vault is empty this quotes at par out of {DeadShares-seedDeposit} rather than
    /// off the ratio, so assets already sitting here cannot price the first deposit, and the seed
    /// is deducted from what the depositor receives. See {DeadShares} for why.
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = totalSupply() == 0 ? DeadShares.seedDeposit(assets) : super.previewDeposit(assets);
    }

    /// @inheritdoc IERC4626
    /// @dev The inverse of {previewDeposit} while empty: the first depositor pays for the seed on
    /// top of the shares they asked for
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() == 0 ? DeadShares.seedMint(shares) : super.previewMint(shares);
    }

    /// @inheritdoc IUnderwriter
    function stakedSupply() public view returns (uint256 supply) {
        uint256 active = activeSupply();
        uint256 dead = balanceOf(DeadShares.HOLDER);
        supply = active > dead ? active - dead : 0;
    }

    /// @inheritdoc IUnderwriter
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IUnderwriter) returns (uint256) {
        return previewWithdraw(IVault(vault).balanceOf(address(this), asset()));
    }

    /// @dev Update the distributed premiums. Staked capital is `stakedSupply`, so shares queued
    /// for redemption stop earning and the dead shares never do; see {PremiumVesting-accrue} for
    /// what happens to premium vesting through a window where that reaches zero.
    function _updatePremiums() internal {
        _premium.accrue(stakedSupply());
    }

    /// @dev Settle premium accounting when shares move
    function _update(address from, address to, uint256 amount) internal override {
        _updatePremiums();
        if (from != address(0) && from != address(this)) {
            uint256 balance = balanceOf(from);
            _premium.checkpoint(from, balance, balance - amount);
        }
        if (to != address(0) && to != address(this)) {
            uint256 balance = balanceOf(to);
            _premium.checkpoint(to, balance, balance + amount);
        }
        super._update(from, to, amount);
    }

    /// @dev Mint the seed alongside the first deposit. {previewDeposit} and {previewMint} have
    /// already taken it out of that depositor's quote, so the assets arriving cover both.
    /// @param caller The account funding the deposit
    /// @param receiver The account receiving the shares
    /// @param assets The number of assets deposited
    /// @param shares The number of shares to mint to the receiver
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (totalSupply() == 0) _mint(DeadShares.HOLDER, DeadShares.SHARES);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Transfer in assets to the vault from the sender
    /// @param from The address of the sender
    /// @param assets The amount of assets to transfer in
    function _transferIn(address from, uint256 assets) internal override {
        IVault(vault).transferFrom(from, address(this), asset(), assets);

        if (defaultTranche != address(0)) {
            _allocate(defaultTranche, assets);
        }
    }

    /// @dev Transfer out assets from the vault to the receiver
    /// @param to The address of the receiver
    /// @param assets The amount of assets to transfer out
    function _transferOut(address to, uint256 assets) internal override {
        IVault(vault).transfer(to, asset(), assets);
    }

    /// @inheritdoc IERC1155Receiver
    /// @dev Accepting the queue receipt is what makes an async deallocation possible at all: the
    /// receipt is minted to the controller, {deallocateAsync} names this contract as its own
    /// controller, and a mint to a contract that refuses ERC-1155 reverts, so the whole path was
    /// unreachable without this. Unconditional, as {ERC1155Holder} is. A receipt this contract did
    /// not ask for changes nothing, because {finalizeDeallocateAsync} settles only against ids
    /// recorded by {deallocateAsync} and the mark is read from those.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    /// @dev The queue only ever mints one id at a time, so nothing here produces a batch; accepted
    /// for the same reason as the single form, to complete the interface this claims to support
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC7540AsyncRedeem, IERC165) returns (bool) {
        return interfaceId == type(IUnderwriter).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
