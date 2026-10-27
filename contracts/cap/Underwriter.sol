// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IPremiumVesting } from "../interfaces/IPremiumVesting.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley, Cap Labs
/// @notice Curator vault that allocates assets into tranches and distributes premium to depositors.
/// @dev Beacon instance. Upgrade via {UpgradeableBeacon-upgradeTo} on the underwriter beacon.
contract Underwriter layout at erc7201("cap.storage.Underwriter") is IUnderwriter, PremiumVesting {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @inheritdoc IUnderwriter
    address public registry;

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

    /// @inheritdoc IUnderwriter
    uint256 public lastReported;

    /// @inheritdoc IUnderwriter
    bool public killed;

    /// @dev Shares per remaining asset at which the pool is retired (1% of par at one asset per share).
    uint256 private constant KILL_RATIO = 100;

    /// @dev Reject a target that cannot be a tranche; see {_validTranche}
    /// @param tranche The tranche to check
    modifier validTranche(address tranche) {
        _validTranche(tranche);
        _;
    }

    /// @inheritdoc IUnderwriter
    function registeredTranches() external view returns (address[] memory) {
        return _registeredTranches.values();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IUnderwriter
    function initialize(
        address _authority,
        address _registry,
        string memory _name,
        string memory _symbol,
        address _asset,
        address _stablecoinAddress,
        uint256 _vestingPeriod
    ) external override initializer {
        __PremiumVesting_init(_authority, IERC20(_asset), _name, _symbol, _stablecoinAddress, _vestingPeriod);
        registry = _registry;
    }

    /// @inheritdoc IUnderwriter
    function setDepositorRole(uint64 roleId) external restricted {
        IRegistry(registry).setDepositorRole(roleId);
    }

    /// @inheritdoc IUnderwriter
    function setAllocatorRole(uint64 roleId) external restricted {
        IRegistry(registry).setAllocatorRole(roleId);
    }

    /// @inheritdoc IUnderwriter
    function addTranche(address _tranche) external restricted {
        // only a tranche the registry deployed, in this pool's asset, may be allocated to. It holds
        // no standing approval: {_allocate} approves exactly what each deposit pulls
        if (!IRegistry(registry).isTranche(_tranche) || ITranche(_tranche).asset() != asset()) {
            revert InvalidTranche();
        }
        _registeredTranches.add(_tranche);
        // this vault holds the tranche shares and claims them in {report}, so it has to earn.
        // A third-party market holding the same token would stay out
        IPremiumVesting(_tranche).optIn();
        emit AddTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function removeTranche(address _tranche) external restricted {
        if (debt[_tranche] > 0) _report(_tranche);
        _registeredTranches.remove(_tranche);
        // every deposit routes through {_transferIn} into {_allocate}, which insists on
        // registration, so a deregistered tranche left as the default would revert each one.
        // Clearing it holds incoming assets here instead, which is what an unset default
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
    /// @param tranche The tranche to deposit into
    /// @param assets The amount of assets to allocate
    function _allocate(address tranche, uint256 assets) internal {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        // remake first so an unmarked slash is Loss, not netted into Allocated
        _mark(tranche);
        // buy whole shares at their exact price so any remainder stays idle instead of
        // being donated to the tranche's holders; the approval is spent in the same call
        uint256 trancheShares = ITranche(tranche).previewDeposit(assets);
        if (trancheShares == 0) return;
        uint256 cost = ITranche(tranche).previewMint(trancheShares);
        IERC20(asset()).forceApprove(tranche, cost);
        ITranche(tranche).mint(trancheShares, address(this));
        // allocate is the only path that may open a book
        _applyAllocated(tranche);
        _checkKilled();
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares)
        external
        restricted
        validTranche(tranche)
        returns (uint256 deallocated)
    {
        // remake first so an unmarked slash is Loss, not netted into Deallocated
        _mark(tranche);
        // clamped by this contract's own holding as well as the tranche's unlocked supply, so an
        // oversized request comes back as a short fill the way {deallocateAsync} does rather than
        // reverting inside the tranche's burn
        uint256 available =
            Math.min(ITranche(tranche).balanceOf(address(this)), ITranche(tranche).instantUnlockedSupply());
        deallocated = Math.min(shares, available);
        if (deallocated > 0) ITranche(tranche).instantRedeem(deallocated, address(this), address(this));
        // remakes an existing book only. An airdropped vault cannot enter {totalDebt} here.
        _applyDeallocated(tranche);
        _checkKilled();
    }

    /// @inheritdoc IUnderwriter
    function deallocateAsync(address tranche, uint256 shares)
        external
        restricted
        validTranche(tranche)
        returns (uint256 requestId)
    {
        uint256 balance = ITranche(tranche).balanceOf(address(this));
        if (shares > balance) shares = balance;

        // the request stays in {debt}, so this remake is gain/loss only
        _mark(tranche);

        requestId = ITranche(tranche).requestRedeem(shares, address(this), address(this));

        // the request itself gives nothing up, so these two only move the position from one column
        // to the other: the shares have left this contract's balance for the tranche's own, and
        // this is what keeps {_mark} able to see them while they sit there
        queuedShares[tranche] += shares;
        queuedRequest[tranche][requestId] = shares;

        emit RequestedRedeem(tranche, shares, requestId);
    }

    /// @inheritdoc IUnderwriter
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares)
        external
        restricted
        validTranche(tranche)
    {
        // a request is only settled down against what this contract queued under that id. Anyone
        // can name this vault as the controller of a redemption they request against their own
        // shares, which mints a receipt here that no allocation of ours backs. Settling one of
        // those against the aggregate would retire shares still genuinely queued and take the mark
        // back below the position, so an unrecognised id is refused and the gift simply ignored.
        uint256 recorded = queuedRequest[tranche][requestId];
        if (shares > recorded) revert UnknownQueuedRequest();

        _mark(tranche);

        ITranche(tranche).redeem(requestId, shares, address(this), address(this));

        queuedRequest[tranche][requestId] = recorded - shares;
        queuedShares[tranche] -= shares;

        _applyDeallocated(tranche);
        _checkKilled();
    }

    /// @dev This contract's own shares are user redemption escrow and its cUSD is the premium pot,
    /// so neither may be treated as a tranche position.
    /// @param tranche The tranche to check
    function _validTranche(address tranche) internal view {
        if (tranche == address(this) || tranche == stablecoin()) revert InvalidTranche();
    }

    /// @dev Remaining plus queued shares, in asset units
    /// @param tranche The tranche to price
    /// @return The live convert-to-assets of this vault's position
    function _positionAssets(address tranche) internal view returns (uint256) {
        uint256 position = ITranche(tranche).balanceOf(address(this)) + queuedShares[tranche];
        return ITranche(tranche).convertToAssets(position);
    }

    /// @dev Re-value a book that {allocate} already opened. A never-seen token is a no-op, so an
    /// airdropped vault cannot enter {totalDebt} through deallocate, finalize, or report.
    /// @param tranche The tranche to re-value
    /// @return gain The increase in the recorded position, if any
    /// @return loss The decrease in the recorded position, if any
    function _mark(address tranche) internal returns (uint256 gain, uint256 loss) {
        if (debt[tranche] == 0) {
            _checkKilled();
            return (0, 0);
        }
        return _syncMark(tranche);
    }

    /// @dev Write {debt} from remaining plus queued shares. The book stays cached between marks;
    /// issuance quotes separately value the default position via {_issuanceAssets}.
    /// @param tranche The tranche to re-value
    /// @return gain The increase in the recorded position, if any
    /// @return loss The decrease in the recorded position, if any
    function _syncMark(address tranche) internal returns (uint256 gain, uint256 loss) {
        uint256 recorded = debt[tranche];
        uint256 assets = _positionAssets(tranche);

        if (assets < recorded) {
            loss = recorded - assets;
            totalDebt -= loss;
            emit Loss(tranche, loss);
        } else if (assets > recorded) {
            gain = assets - recorded;
            totalDebt += gain;
            emit Gain(tranche, gain);
        }
        debt[tranche] = assets;
        _checkKilled();
    }

    /// @dev Latch retirement after updating a position, including an unchanged or closed book.
    /// Exits, reports, and premium claims remain available after retirement.
    function _checkKilled() private {
        if (!killed && _belowKillThreshold(false)) {
            killed = true;
            emit Killed();
        }
    }

    /// @dev Division avoids overflowing assets * 100. A never-funded pool is not a loss and reads
    /// no assets; equality at the threshold remains open.
    /// @param live Value the default position live, as issuance does, instead of at its last mark
    function _belowKillThreshold(bool live) private view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return false;
        uint256 assets = live ? _issuanceAssets() : totalAssets();
        return assets < Math.ceilDiv(supply, KILL_RATIO);
    }

    /// @dev Fold a deposit into {debt}. First allocation opens the book.
    /// @param tranche The tranche that received the deposit
    function _applyAllocated(address tranche) internal {
        uint256 marked = debt[tranche];
        uint256 assets = _positionAssets(tranche);
        if (assets <= marked) return;
        uint256 added = assets - marked;
        debt[tranche] = assets;
        totalDebt += added;
        emit Allocated(tranche, added);
    }

    /// @dev Fold a redemption into {debt}. A never-seen token is a no-op.
    /// @param tranche The tranche that was redeemed
    function _applyDeallocated(address tranche) internal {
        uint256 marked = debt[tranche];
        if (marked == 0) return;
        uint256 assets = _positionAssets(tranche);
        if (assets >= marked) return;
        uint256 removed = marked - assets;
        debt[tranche] = assets;
        totalDebt -= removed;
        emit Deallocated(tranche, removed);
    }

    /// @inheritdoc IUnderwriter
    function setDefaultTranche(address tranche) external restricted {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        defaultTranche = tranche;
        emit SetDefaultTranche(tranche);
    }

    /// @inheritdoc IUnderwriter
    function report(address _tranche) external restricted {
        _report(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function recoverRemainder(address recipient) external restricted returns (uint256 amount) {
        // a live pool can still take deposits that opt in
        if (!killed) revert RemainderStillClaimable();
        amount = _recoverRemainder(recipient);
    }

    /// @inheritdoc IUnderwriter
    function deposit(uint256 _assets, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        restricted
        returns (uint256 shares)
    {
        shares = super.deposit(_assets, _receiver);
    }

    /// @inheritdoc IUnderwriter
    function mint(uint256 _shares, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        restricted
        returns (uint256 assets)
    {
        assets = super.mint(_shares, _receiver);
    }

    /// @inheritdoc IUnderwriter
    function maxDeposit(address)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 maxAssets)
    {
        if (_depositsOpen()) {
            maxAssets = type(uint256).max;
        }
    }

    /// @inheritdoc IUnderwriter
    function maxMint(address)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 maxShares)
    {
        if (_depositsOpen()) {
            maxShares = type(uint256).max;
        }
    }

    /// @dev A killed default, or one that no longer admits this pool as a depositor, blocks new
    /// capital without retiring an otherwise healthy pool.
    /// @return open Whether the pool and its default tranche permit new capital
    function _depositsOpen() private view returns (bool) {
        // the live value deposits are priced at, so a stale mark cannot keep a dead pool open
        if (killed || _belowKillThreshold(true)) {
            return false;
        }
        address tranche = defaultTranche;
        if (tranche != address(0)) {
            if (ITranche(tranche).killed()) return false;
            // every deposit is forwarded to the default tranche, gated on this pool's admission there
            (bool admitted,) = IAccessManager(authority()).canCall(address(this), tranche, IERC4626.deposit.selector);
            if (!admitted) return false;
        }

        return true;
    }

    /// @inheritdoc IUnderwriter
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IUnderwriter) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalDebt;
    }

    /// @dev Replace the default position's cached value with its current value for issuance only.
    /// Includes queued shares and zero-book positions, as the allocation's {_applyAllocated} does.
    /// Allocation persists the updated book after the incoming assets have been transferred.
    /// @return assets The assets used to price deposits and mints
    function _issuanceAssets() internal view returns (uint256 assets) {
        assets = totalAssets();
        address tranche = defaultTranche;
        if (tranche == address(0)) return assets;

        uint256 recorded = debt[tranche];
        uint256 position = ITranche(tranche).balanceOf(address(this)) + queuedShares[tranche];
        assets = assets - recorded + ITranche(tranche).convertToAssets(position);
    }

    /// @inheritdoc IUnderwriter
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 shares)
    {
        uint256 supply = totalSupply();
        shares = supply == 0
            ? DeadShares.seedDeposit(assets)
            : Math.mulDiv(assets, supply + 10 ** _decimalsOffset(), _issuanceAssets() + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IUnderwriter
    function previewMint(uint256 shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 assets)
    {
        uint256 supply = totalSupply();
        assets = supply == 0
            ? DeadShares.seedMint(shares)
            : Math.mulDiv(shares, _issuanceAssets() + 1, supply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IUnderwriter
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IUnderwriter) returns (uint256 unlocked) {
        uint256 idleAssets = IERC20(asset()).balanceOf(address(this));
        unlocked = _convertToShares(idleAssets, Math.Rounding.Floor);
    }

    /// @dev Mint the seed on the first deposit. Already deducted from the quote.
    /// @param caller The account funding the deposit
    /// @param receiver The account receiving the shares
    /// @param assets The number of assets deposited
    /// @param shares The number of shares to mint to the receiver
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (totalSupply() == 0) _mint(DeadShares.HOLDER, DeadShares.SHARES);
        super._deposit(caller, receiver, assets, shares);
        // Default allocation can recognize a loss after the entry-point limit check, and its kill
        // check ran before these shares existed. Allocation has marked the default, so its book is
        // live (others stay cached); test the completed ratio.
        if (killed || _belowKillThreshold(false)) revert UnderwriterKilled();
    }

    /// @dev Pull the deposit, then route it to the default tranche if one is set
    /// @param from The address of the sender
    /// @param assets The amount of assets to transfer in
    function _transferIn(address from, uint256 assets) internal override {
        super._transferIn(from, assets);

        if (defaultTranche != address(0)) {
            _allocate(defaultTranche, assets);
        }
    }

    /// @dev Re-value an already-opened book and claim premium from a Registry-deployed tranche.
    /// Allocation registration is not required: {removeTranche} only closes new allocations,
    /// and leftover shares keep earning until they are redeemed.
    /// @param _tranche The tranche to report
    function _report(address _tranche) internal {
        if (!IRegistry(registry).isTranche(_tranche)) revert UnknownTranche();
        (uint256 gain, uint256 loss) = _mark(_tranche);

        uint256 premium = IPremiumVesting(_tranche).claim(address(this));
        // Harvested premium vests again at the pool's configured rate. Holders earn as it
        // vests here, including those who joined after the tranche generated the premium.
        _fund(premium);
        lastReported = block.timestamp;

        emit Reported(_tranche, premium, gain, loss);
    }
}
