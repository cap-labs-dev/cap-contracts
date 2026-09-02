// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
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
    using WadRayMath for uint256;

    /// @inheritdoc IUnderwriter
    address public vault;

    /// @inheritdoc IUnderwriter
    address public stablecoin;

    /// @inheritdoc IUnderwriter
    uint256 public vestingPeriod;

    /// @inheritdoc IUnderwriter
    uint256 public lastReported;

    /// @inheritdoc IUnderwriter
    uint256 public vestedPremium;

    /// @inheritdoc IUnderwriter
    uint256 public premiumPerSecond;

    /// @inheritdoc IUnderwriter
    uint256 public lastPremiumUpdate;

    /// @inheritdoc IUnderwriter
    uint256 public premiumPerShare;

    /// @inheritdoc IUnderwriter
    address public defaultTranche;

    /// @inheritdoc IUnderwriter
    mapping(address => uint256) public debt;

    /// @inheritdoc IUnderwriter
    uint256 public totalDebt;

    /// @dev The list of registered tranches
    EnumerableSet.AddressSet private _registeredTranches;

    /// @inheritdoc IUnderwriter
    mapping(address => uint256) public pendingPremium;

    /// @dev Premium already credited to an account at its last balance checkpoint
    mapping(address => uint256) private _premiumDebt;

    /// @dev The whitelist of accounts
    EnumerableSet.AddressSet private _whitelist;

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
        vestingPeriod = 6 hours;
    }

    /// @inheritdoc IUnderwriter
    function addTranche(address _tranche) external restricted {
        _registeredTranches.add(_tranche);
        emit AddTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function removeTranche(address _tranche) external restricted {
        _registeredTranches.remove(_tranche);
        emit RemoveTranche(_tranche);
    }

    /// @inheritdoc IUnderwriter
    function allocate(address tranche, uint256 assets) external restricted {
        _allocate(tranche, assets);
    }

    /// @dev Allocate assets to a tranche
    function _allocate(address tranche, uint256 assets) internal {
        if (!_registeredTranches.contains(tranche)) revert NotRegisteredTranche();
        IVault(vault).setOperator(tranche, true);
        uint256 shares = ITranche(tranche).deposit(assets, address(this));
        uint256 newDebt = ITranche(tranche).previewRedeem(shares);

        debt[tranche] += newDebt;
        totalDebt += newDebt;
        emit DebtIncreased(tranche, newDebt);
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares) external restricted returns (uint256 deallocated) {
        uint256 unlockedShares = ITranche(tranche).instantUnlockedSupply();
        deallocated = unlockedShares < shares ? unlockedShares : shares;
        if (deallocated > 0) {
            uint256 withdrawn = IERC4626(tranche).redeem(deallocated, address(this), address(this));
            debt[tranche] -= withdrawn;
            totalDebt -= withdrawn;
            emit DebtDecreased(tranche, withdrawn);
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
        uint256 withdrawn = ITranche(tranche).redeem(requestId, shares, address(this), address(this));
        debt[tranche] -= withdrawn;
        totalDebt -= withdrawn;
        emit DebtDecreased(tranche, withdrawn);
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
        uint256 leftover = vestedReward();
        vestingPeriod = _vestingPeriod;
        vestedPremium = leftover;
        premiumPerSecond = leftover / _vestingPeriod;
        lastReported = block.timestamp;
        lastPremiumUpdate = block.timestamp;
        emit SetVestingPeriod(_vestingPeriod);
    }

    /// @inheritdoc IUnderwriter
    function whitelist(address account, bool allowed) external restricted {
        if (allowed) _whitelist.add(account);
        else _whitelist.remove(account);
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
        vestedPremium = vestedReward() + premium;
        premiumPerSecond = vestedPremium / vestingPeriod;
        lastReported = block.timestamp;
        lastPremiumUpdate = block.timestamp;

        emit Reported(_tranche, premium, gain, loss);
    }

    /// @inheritdoc IUnderwriter
    function claim() external {
        _updatePremiums();
        uint256 premium = _claimable(msg.sender);
        if (premium == 0) return;
        pendingPremium[msg.sender] = 0;
        _premiumDebt[msg.sender] = premiumPerShare.rayMul(balanceOf(msg.sender));
        IERC20(stablecoin).safeTransfer(msg.sender, premium);
    }

    /// @inheritdoc IUnderwriter
    function claimable(address user) external view returns (uint256 premium) {
        premium = _claimable(user);
    }

    /// @dev Get the claimable premium for a user
    function _claimable(address user) internal view returns (uint256 premium) {
        uint256 perShare = premiumPerShare;
        uint256 supply = activeSupply();
        uint256 accrueUntil = Math.min(block.timestamp, vestingEnd());
        if (supply > 0 && accrueUntil > lastPremiumUpdate) {
            perShare += (premiumPerSecond * (accrueUntil - lastPremiumUpdate)).rayDiv(supply);
        }
        premium = pendingPremium[user] + perShare.rayMul(balanceOf(user)) - _premiumDebt[user];
    }

    /// @inheritdoc IUnderwriter
    function vestedReward() public view returns (uint256 vested) {
        uint256 elapsed = block.timestamp - lastReported;
        if (elapsed >= vestingPeriod) return 0;
        vested = vestedPremium * (vestingPeriod - elapsed) / vestingPeriod;
    }

    /// @inheritdoc IUnderwriter
    function vestingEnd() public view returns (uint256 end) {
        end = lastReported + vestingPeriod;
    }

    /// @inheritdoc IUnderwriter
    function whitelisted(address account) public view returns (bool allowed) {
        allowed = _whitelist.contains(account);
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

    /// @dev Update the distributed premiums
    /// @dev Accrual stops at vestingEnd. That boundary can move backwards when the vesting period
    /// is shortened, so it is clamped rather than subtracted from directly.
    function _updatePremiums() internal {
        uint256 accrueUntil = Math.min(block.timestamp, vestingEnd());
        if (accrueUntil <= lastPremiumUpdate) return;
        uint256 supply = activeSupply();
        // leave lastPremiumUpdate alone while nothing is staked, so the premium for that window is
        // carried into the next accrual instead of being burned
        if (supply == 0) return;
        premiumPerShare += (premiumPerSecond * (accrueUntil - lastPremiumUpdate)).rayDiv(supply);
        lastPremiumUpdate = accrueUntil;
    }

    /// @dev Settle premium accounting when shares move
    function _update(address from, address to, uint256 amount) internal override {
        _updatePremiums();
        if (from != address(0) && from != address(this)) {
            pendingPremium[from] += premiumPerShare.rayMul(balanceOf(from)) - _premiumDebt[from];
            _premiumDebt[from] = premiumPerShare.rayMul(balanceOf(from) - amount);
        }
        if (to != address(0) && to != address(this)) {
            pendingPremium[to] += premiumPerShare.rayMul(balanceOf(to)) - _premiumDebt[to];
            _premiumDebt[to] = premiumPerShare.rayMul(balanceOf(to) + amount);
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
