// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    ERC4626Upgradeable,
    ERC7540AsyncRedeem,
    IERC4626,
    IERC7540AsyncRedeem
} from "../ERC7540/ERC7540AsyncRedeem.sol";
import { ILender } from "../interfaces/ILender.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { UnderwriterStorageUtils } from "../storage/UnderwriterStorageUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley
/// @notice The Vault is a contract that allows users to deposit and withdraw ERC20 assets.
contract Underwriter is
    IUnderwriter,
    AccessManagedUpgradeable,
    ERC7540AsyncRedeem,
    UnderwriterStorageUtils,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using WadRayMath for uint256;

    /// @inheritdoc IUnderwriter
    function initialize(
        address _authority,
        string memory _name,
        string memory _symbol,
        address _asset,
        address _vault,
        address _lender,
        address _rewardToken
    ) external initializer {
        Storage storage $ = getUnderwriterStorage();
        __AccessManaged_init(_authority);
        __ERC7540AsyncRedeem_init(IERC20(_asset), _name, _symbol, hex"");
        $.vault = _vault;
        $.lender = _lender;
        $.rewardToken = _rewardToken;
        $.vestingPeriod = 6 hours;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Allocation functions ***************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IUnderwriter
    function allocate(address tranche, uint256 assets) external restricted {
        _allocate(tranche, assets);
    }

    /// @dev Allocate assets to a tranche
    function _allocate(address tranche, uint256 assets) internal {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();

        IERC20(asset()).forceApprove(tranche, assets);
        uint256 shares = ITranche(tranche).deposit(assets, address(this));
        uint256 debt = ITranche(tranche).previewRedeem(shares);

        $.debt[tranche] += debt;
        $.totalDebt += debt;
        emit DebtIncreased(tranche, debt);
    }

    /// @inheritdoc IUnderwriter
    function requestDeallocate(address tranche, uint256 shares) external restricted returns (uint256 requestId) {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();
        uint256 balance = ITranche(tranche).balanceOf(address(this));
        if (shares > balance) shares = balance;

        requestId = ITranche(tranche).requestRedeem(shares, address(this), address(this));
        emit RequestedRedeem(tranche, shares, requestId);
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 shares) external restricted returns (uint256 deallocated) {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();

        uint256 unlockedShares = ITranche(tranche).instantUnlockedSupply();
        deallocated = unlockedShares < shares ? unlockedShares : shares;
        if (deallocated > 0) {
            uint256 withdrawn = IERC4626(tranche).redeem(deallocated, address(this), address(this));
            $.debt[tranche] -= withdrawn;
            $.totalDebt -= withdrawn;
            emit DebtDecreased(tranche, withdrawn);
        }
    }

    /// @inheritdoc IUnderwriter
    function deallocate(address tranche, uint256 requestId, uint256 shares) external restricted {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();

        uint256 withdrawn = ITranche(tranche).redeem(requestId, shares, address(this), address(this));
        $.debt[tranche] -= withdrawn;
        $.totalDebt -= withdrawn;
        emit DebtDecreased(tranche, withdrawn);
    }

    /// @inheritdoc IUnderwriter
    function setDefaultTranche(address tranche) external restricted {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();
        $.defaultTranche = tranche;
        emit SetDefaultTranche(tranche);
    }

    /// @inheritdoc IUnderwriter
    function setVestingPeriod(uint256 vestingPeriod) external restricted {
        Storage storage $ = getUnderwriterStorage();
        if (vestingPeriod == 0) revert InvalidVestingPeriod();
        $.vestingPeriod = vestingPeriod;
        emit SetVestingPeriod(vestingPeriod);
    }

    /// @inheritdoc IUnderwriter
    function report(address tranche) external restricted {
        Storage storage $ = getUnderwriterStorage();
        if (!ILender($.lender).isTranche(tranche)) revert InvalidTranche();

        uint256 debt = $.debt[tranche];
        uint256 assets = ITranche(tranche).previewRedeem(ITranche(tranche).balanceOf(address(this)));

        if (assets != debt) {
            if (assets < debt) {
                uint256 loss = debt - assets;
                $.totalDebt -= loss;
                emit DebtDecreased(tranche, loss);
            } else {
                uint256 gain = assets - debt;
                $.totalDebt += gain;
                emit DebtIncreased(tranche, gain);
            }
            $.debt[tranche] = assets;
        }

        uint256 reward = ILender($.lender).claimTrancheReward(tranche, address(this));
        $.vestedReward = vestedReward() + reward;
        $.rewardPerSecond = $.vestedReward.rayDiv($.vestingPeriod);
        $.lastReported = block.timestamp;

        emit Reported(tranche, reward);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Reward functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IUnderwriter
    function claim() external {
        _updateRewards();
        Storage storage $ = getUnderwriterStorage();
        uint256 reward = _claimableReward(msg.sender);
        $.pendingReward[msg.sender] = 0;
        IERC20($.rewardToken).safeTransfer(msg.sender, reward);
    }

    /// @inheritdoc IUnderwriter
    function claimableReward(address user) external view returns (uint256 reward) {
        reward = _claimableReward(user);
    }

    /// @dev Get the claimable reward for a user
    function _claimableReward(address user) internal view returns (uint256 reward) {
        Storage storage $ = getUnderwriterStorage();
        uint256 accumulatedReward;
        uint256 supply = activeSupply();
        if ($.lastRewardUpdate == block.timestamp || supply == 0) {
            accumulatedReward = $.rewardPerShare.rayMul(balanceOf(user));
        } else {
            uint256 end = vestingEnd();
            uint256 elapsed = (block.timestamp > end) ? end - $.lastRewardUpdate : block.timestamp - $.lastRewardUpdate;
            accumulatedReward =
                ($.rewardPerShare + $.rewardPerSecond.rayMul(elapsed).rayDiv(supply)).rayMul(balanceOf(user));
        }
        reward = $.pendingReward[user] + accumulatedReward - $.rewardDebt[user];
    }

    /// @inheritdoc IUnderwriter
    function vestedReward() public view returns (uint256 vested) {
        Storage storage $ = getUnderwriterStorage();
        uint256 elapsed = block.timestamp - $.lastReported;
        if (elapsed >= $.vestingPeriod) return 0;
        vested = $.vestedReward.rayMul(1e27 - elapsed.rayDiv($.vestingPeriod));
    }

    /// @inheritdoc IUnderwriter
    function vestingEnd() public view returns (uint256 end) {
        Storage storage $ = getUnderwriterStorage();
        end = $.lastReported + $.vestingPeriod;
    }

    /// @dev Update the distributed rewards
    function _updateRewards() internal {
        Storage storage $ = getUnderwriterStorage();
        uint256 elapsed;
        uint256 end = vestingEnd();
        if (block.timestamp > end) {
            elapsed = end - $.lastRewardUpdate;
            if (elapsed == 0) return;
            $.lastRewardUpdate = end;
        } else {
            elapsed = block.timestamp - $.lastRewardUpdate;
            $.lastRewardUpdate = block.timestamp;
        }
        uint256 supply = activeSupply();
        if (supply == 0) return;
        $.rewardPerShare += $.rewardPerSecond.rayMul(elapsed).rayDiv(supply);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC4626 functions *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IUnderwriter
    function whitelist(address account, bool allowed) external restricted {
        Storage storage $ = getUnderwriterStorage();
        if (allowed) $.whitelist.add(account);
        else $.whitelist.remove(account);
    }

    /// @inheritdoc IUnderwriter
    function vault() external view returns (address) {
        return getUnderwriterStorage().vault;
    }

    /// @inheritdoc IUnderwriter
    function lender() external view returns (address) {
        return getUnderwriterStorage().lender;
    }

    /// @inheritdoc IUnderwriter
    function rewardToken() external view returns (address) {
        return getUnderwriterStorage().rewardToken;
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        Storage storage $ = getUnderwriterStorage();
        return IVault($.vault).balanceOf(address(this), asset()) + $.totalDebt;
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxAssets)
    {
        if (whitelisted(receiver)) maxAssets = type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 maxShares) {
        if (whitelisted(receiver)) maxShares = type(uint256).max;
    }

    /// @inheritdoc IUnderwriter
    function whitelisted(address account) public view returns (bool allowed) {
        allowed = getUnderwriterStorage().whitelist.contains(account);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IERC7540AsyncRedeem) returns (uint256) {
        Storage storage $ = getUnderwriterStorage();
        return previewWithdraw(IVault($.vault).balanceOf(address(this), asset()));
    }

    /// @notice Override the _update function to update the sender and receiver's rewards
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param amount The amount of assets transferred
    function _update(address from, address to, uint256 amount) internal override {
        _updateRewards();
        Storage storage $ = getUnderwriterStorage();
        if (from != address(0) && from != address(this)) {
            $.pendingReward[from] += $.rewardPerShare.rayMul(balanceOf(from)) - $.rewardDebt[from];
            $.rewardDebt[from] = $.rewardPerShare.rayMul(balanceOf(from) - amount);
        }
        if (to != address(0) && to != address(this)) {
            $.pendingReward[to] += $.rewardPerShare.rayMul(balanceOf(to)) - $.rewardDebt[to];
            $.rewardDebt[to] = $.rewardPerShare.rayMul(balanceOf(to) + amount);
        }
        super._update(from, to, amount);
    }

    /// @dev Transfer in assets to the vault from the sender
    /// @param from The address of the sender
    /// @param assets The amount of assets to transfer in
    function _transferIn(address from, uint256 assets) internal override {
        Storage storage $ = getUnderwriterStorage();
        IVault($.vault).transferFrom(from, address(this), asset(), assets);

        if ($.defaultTranche != address(0)) {
            _allocate($.defaultTranche, assets);
        }
    }

    /// @dev Transfer out assets from the vault to the receiver
    /// @param to The address of the receiver
    /// @param assets The amount of assets to transfer out
    function _transferOut(address to, uint256 assets) internal override {
        Storage storage $ = getUnderwriterStorage();
        IVault($.vault).transfer(to, asset(), assets);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IUnderwriter).interfaceId || super.supportsInterface(interfaceId);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
