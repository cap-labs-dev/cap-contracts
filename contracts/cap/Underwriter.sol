// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IPremiumVesting } from "../interfaces/IPremiumVesting.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley, Cap Labs
/// @notice Curator vault that allocates assets into tranches and distributes premium to depositors.
/// @dev Beacon instance. Upgrade via {UpgradeableBeacon-upgradeTo} on the underwriter beacon.
contract Underwriter layout at erc7201("cap.storage.Underwriter") is IUnderwriter, PremiumVesting {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IUnderwriter
    address public registry;

    /// @inheritdoc IUnderwriter
    address public vault;

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
        address _vaultAddress,
        address _stablecoinAddress,
        uint256 _vestingPeriod
    ) external override initializer {
        __PremiumVesting_init(_authority, IERC20(_asset), _name, _symbol, _stablecoinAddress, _vestingPeriod);
        registry = _registry;
        vault = _vaultAddress;
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
        _registeredTranches.add(_tranche);
        // curator is trusted to name a real protocol tranche for this vault and asset. The tranche
        // pulls this contract's vault balance on deposit, so it needs operator rights for as long
        // as it is registered and no longer
        IVault(vault).setOperator(_tranche, true);
        // this vault holds the tranche shares and claims them in {report}, so it has to earn.
        // A third-party market holding the same token would stay out
        IPremiumVesting(_tranche).optIn();
        emit AddTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function removeTranche(address _tranche) external restricted {
        if (debt[_tranche] > 0) _report(_tranche);
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
    /// @param tranche The tranche to deposit into
    /// @param assets The amount of assets to allocate
    function _allocate(address tranche, uint256 assets) internal {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        ITranche(tranche).deposit(assets, address(this));
        // allocate is the only path that may open a book
        _syncMark(tranche);
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares) external restricted returns (uint256 deallocated) {
        // clamped by this contract's own holding as well as the tranche's unlocked supply, so an
        // oversized request comes back as a short fill the way {deallocateAsync} does rather than
        // reverting inside the tranche's burn
        uint256 available =
            Math.min(ITranche(tranche).balanceOf(address(this)), ITranche(tranche).instantUnlockedSupply());
        deallocated = Math.min(shares, available);
        if (deallocated > 0) ITranche(tranche).instantRedeem(deallocated, address(this), address(this));
        // remakes an existing book only. An airdropped vault cannot enter {totalDebt} here.
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

    /// @dev Re-value a book that {allocate} already opened. A never-seen token is a no-op, so an
    /// airdropped vault cannot enter {totalDebt} through deallocate, finalize, or report.
    /// @param tranche The tranche to re-value
    /// @return gain The increase in the recorded position, if any
    /// @return loss The decrease in the recorded position, if any
    function _mark(address tranche) internal returns (uint256 gain, uint256 loss) {
        if (debt[tranche] == 0) return (0, 0);
        return _syncMark(tranche);
    }

    /// @dev Write {debt} from remaining plus queued shares. A slash between reports is a loss that
    /// waits here on purpose: share price is this cached book, not a live walk of every position.
    /// @param tranche The tranche to re-value
    /// @return gain The increase in the recorded position, if any
    /// @return loss The decrease in the recorded position, if any
    function _syncMark(address tranche) internal returns (uint256 gain, uint256 loss) {
        uint256 recorded = debt[tranche];
        uint256 position = ITranche(tranche).balanceOf(address(this)) + queuedShares[tranche];
        uint256 assets = ITranche(tranche).convertToAssets(position);
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
    function report(address _tranche) external restricted {
        _report(_tranche);
    }

    /// @inheritdoc IERC4626
    /// @dev Caller must have the depositor role. The receiver is unrestricted.
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
    /// @dev Idle vault balance plus the last marked tranche positions. A slash hits the tranche
    /// immediately, but this vault only folds it in when {_mark} runs (allocate, deallocate, or
    /// report). Positions are not priced live.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IUnderwriter) returns (uint256) {
        return IVault(vault).balanceOf(address(this), asset()) + totalDebt;
    }

    /// @inheritdoc IERC4626
    /// @dev Empty vault quotes at par via {DeadShares-seedDeposit} minus the seeded shares.
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = totalSupply() == 0 ? DeadShares.seedDeposit(assets) : super.previewDeposit(assets);
    }

    /// @inheritdoc IERC4626
    /// @dev Inverse of {previewDeposit} while empty.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() == 0 ? DeadShares.seedMint(shares) : super.previewMint(shares);
    }

    /// @inheritdoc IUnderwriter
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IUnderwriter) returns (uint256) {
        return _quoteWithdraw(IVault(vault).balanceOf(address(this), asset()));
    }

    /// @dev Mint the seed on the first deposit. Already deducted from the quote.
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

    /// @dev Re-value an already-opened book and claim premium. Registration is not required:
    /// {removeTranche} only closes new allocations, and leftover shares keep earning until they
    /// are redeemed. Gating this the same way as {allocate} stranded that later premium until a
    /// re-add.
    /// @param _tranche The tranche to report
    function _report(address _tranche) internal {
        (uint256 gain, uint256 loss) = _mark(_tranche);

        uint256 premium = IPremiumVesting(_tranche).claim(address(this));
        _fund(premium);
        lastReported = block.timestamp;

        emit Reported(_tranche, premium, gain, loss);
    }
}
