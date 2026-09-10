// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IPremiumVesting } from "../interfaces/IPremiumVesting.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley, Cap Labs
/// @notice Curator vault that allocates assets into tranches and distributes premium to depositors.
contract Underwriter layout at erc7201("cap.storage.Underwriter")
    is
    IUnderwriter,
    ERC1155Holder,
    AccessManagedUpgradeable,
    PremiumVesting,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

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
        string memory _name,
        string memory _symbol,
        address _asset,
        address _vaultAddress,
        address _stablecoinAddress
    ) external override initializer {
        __AccessManaged_init(_authority);
        __PremiumVesting_init(IERC20(_asset), _name, _symbol, hex"", _stablecoinAddress);
        vault = _vaultAddress;
    }

    /// @inheritdoc IUnderwriter
    function addTranche(address _tranche) external restricted {
        _registeredTranches.add(_tranche);
        // the tranche pulls this contract's vault balance on deposit, so it needs operator rights
        // for as long as it is registered and no longer
        IVault(vault).setOperator(_tranche, true);
        // this vault holds the tranche shares and claims them in {report}, so it has to earn.
        // A third-party market holding the same token would stay out
        IPremiumVesting(_tranche).optIn();
        emit AddTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function removeTranche(address _tranche) external restricted {
        _report(_tranche);
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

    /// @dev Re-value from remaining plus queued shares. A slash between reports is a loss.
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
        return previewWithdraw(IVault(vault).balanceOf(address(this), asset()));
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

    /// @dev Report a tranche and claim premium
    /// @param _tranche The tranche to report
    function _report(address _tranche) internal {
        if (!_registeredTranches.contains(_tranche)) revert NotRegisteredTranche();
        (uint256 gain, uint256 loss) = _mark(_tranche);

        uint256 premium = IPremiumVesting(_tranche).claim(address(this));
        _fund(premium);
        lastReported = block.timestamp;

        emit Reported(_tranche, premium, gain, loss);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC7540AsyncRedeem, ERC1155Holder)
        returns (bool)
    {
        return interfaceId == type(IUnderwriter).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
