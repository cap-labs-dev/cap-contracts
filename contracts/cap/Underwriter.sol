// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
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
        emit RemoveTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function allocate(address tranche, uint256 assets) external restricted {
        _allocate(tranche, assets);
    }

    /// @dev Allocate assets to a tranche
    function _allocate(address tranche, uint256 assets) internal {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        uint256 shares = ITranche(tranche).deposit(assets, address(this));
        uint256 newDebt = ITranche(tranche).previewRedeem(shares);

        debt[tranche] += newDebt;
        totalDebt += newDebt;
        emit DebtIncreased(tranche, newDebt);
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares) external restricted returns (uint256 deallocated) {
        // clamped by this contract's own holding as well as the tranche's unlocked supply, so an
        // oversized request comes back as a short fill the way {deallocateAsync} does rather than
        // reverting inside the tranche's burn
        uint256 available =
            Math.min(ITranche(tranche).balanceOf(address(this)), ITranche(tranche).instantUnlockedSupply());
        deallocated = Math.min(shares, available);
        if (deallocated > 0) {
            _recordDeallocation(tranche, IERC4626(tranche).redeem(deallocated, address(this), address(this)));
        }
    }

    /// @inheritdoc IUnderwriter
    function deallocateAsync(address tranche, uint256 shares) external restricted returns (uint256 requestId) {
        uint256 balance = ITranche(tranche).balanceOf(address(this));
        if (shares > balance) shares = balance;

        requestId = ITranche(tranche).requestRedeem(shares, address(this), address(this));
        emit RequestedRedeem(tranche, shares, requestId);
    }

    /// @inheritdoc IUnderwriter
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares) external restricted {
        _recordDeallocation(tranche, ITranche(tranche).redeem(requestId, shares, address(this), address(this)));
    }

    /// @dev Write assets returned by a tranche off that tranche's recorded debt.
    ///
    /// `withdrawn` is a figure the tranche chose, so the subtraction is saturated rather than
    /// trusted. It cannot exceed the recorded debt as things stand, because a tranche's share price
    /// never rises: only deposits add assets and only slashing removes them, so a redemption
    /// returns at most what allocation put in. That invariant is real but it lives in {Tranche},
    /// nowhere near the subtraction relying on it, and a tranche upgrade that ever paid out yield
    /// would turn it into an underflow that bricks every deallocation. One comparison buys
    /// independence from it.
    /// @param tranche The tranche the assets came back from
    /// @param withdrawn The assets the tranche returned
    function _recordDeallocation(address tranche, uint256 withdrawn) internal {
        uint256 recorded = debt[tranche];
        uint256 applied = Math.min(withdrawn, recorded);
        debt[tranche] = recorded - applied;
        totalDebt -= applied;
        emit DebtDecreased(tranche, applied);
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
        uint256 trancheDebt = debt[_tranche];
        uint256 assets = ITranche(_tranche).previewRedeem(ITranche(_tranche).balanceOf(address(this)));
        uint256 gain;
        uint256 loss;

        if (assets != trancheDebt) {
            if (assets < trancheDebt) {
                loss = trancheDebt - assets;
                totalDebt -= loss;
                emit DebtDecreased(_tranche, loss);
            } else {
                gain = assets - trancheDebt;
                totalDebt += gain;
                emit DebtIncreased(_tranche, gain);
            }
            debt[_tranche] = assets;
        }

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
        if (premium == 0) return 0;
        IERC20(stablecoin).safeTransfer(msg.sender, premium);
        emit Claimed(msg.sender, premium);
    }

    /// @inheritdoc IUnderwriter
    function claimable(address user) external view returns (uint256 premium) {
        premium = _premium.claimable(user, balanceOf(user), activeSupply());
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
    /// The modifier checks the caller and {maxDeposit} checks the receiver, so depositing on
    /// another account's behalf needs both of them admitted.
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
    function whitelisted(address account) public view returns (bool allowed) {
        (allowed,) = IAccessManager(authority()).canCall(account, address(this), this.deposit.selector);
    }

    /// @inheritdoc IUnderwriter
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IUnderwriter) returns (uint256) {
        return IVault(vault).balanceOf(address(this), asset()) + totalDebt;
    }

    /// @inheritdoc IUnderwriter
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 maxAssets)
    {
        if (whitelisted(receiver)) maxAssets = type(uint256).max;
    }

    /// @inheritdoc IUnderwriter
    function maxMint(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IUnderwriter)
        returns (uint256 maxShares)
    {
        if (whitelisted(receiver)) maxShares = type(uint256).max;
    }

    /// @inheritdoc IUnderwriter
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IUnderwriter) returns (uint256) {
        return previewWithdraw(IVault(vault).balanceOf(address(this), asset()));
    }

    /// @dev Update the distributed premiums. Staked capital is `activeSupply`, so shares queued for
    /// redemption stop earning; see {PremiumVesting-accrue} for what happens to premium vesting
    /// through a window where that reaches zero.
    function _updatePremiums() internal {
        _premium.accrue(activeSupply());
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IUnderwriter).interfaceId || super.supportsInterface(interfaceId);
    }
}
