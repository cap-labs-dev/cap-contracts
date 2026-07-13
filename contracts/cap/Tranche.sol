// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {
    ERC4626Upgradeable,
    ERC7540AsyncRedeem,
    IERC4626,
    IERC7540AsyncRedeem
} from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMarket } from "../interfaces/IMarket.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { TrancheStorageUtils } from "../storage/TrancheStorageUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Tranche
/// @author kexley
/// @notice Tranche is a ERC4626 vault that allows users to deposit via the Vault ERC6909 tokens. cUSD rewards are earned from
/// underwriting the market.
/// @dev Tranche is a specialized ERC4626 vault that is used to underwrite a market. It is used to
/// track the assets of the tranche and the rewards earned from underwriting the market.
contract Tranche is ITranche, AccessManagedUpgradeable, ERC7540AsyncRedeem, TrancheStorageUtils {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    /// @notice Initialize the tranche
    /// @param _authority The authority address
    /// @param _asset The asset to underwrite
    /// @param _name The name of the tranche
    /// @param _symbol The symbol of the tranche
    /// @param _market The market to underwrite
    /// @param _vault The vault to use for the tranche
    /// @param _irm The interest rate model to use for the tranche

    function initialize(
        address _authority,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _market,
        address _vault,
        address _irm,
        address _stablecoin
    ) external initializer {
        __AccessManaged_init(_authority);
        Storage storage $ = getTrancheStorage();
        __ERC7540AsyncRedeem_init(IERC20(_asset), _name, _symbol, hex"");
        $.market = _market;
        $.vault = _vault;
        $.irm = _irm;
        $.stablecoin = _stablecoin;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Slash functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Slash the tranche's assets
    /// @param assets The amount of assets to slash
    /// @return slashedAssets The amount of assets slashed
    function slash(uint256 assets, address recipient) external returns (uint256 slashedAssets) {
        Storage storage $ = getTrancheStorage();
        if (msg.sender != $.market) revert Unauthorized();
        slashedAssets = Math.min(assets, totalAssets());
        IVault($.vault).withdraw(asset(), slashedAssets, recipient);
        updateIrm();
        emit Slashed(recipient, slashedAssets);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Whitelist functions ***************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Set the whitelist for a depositor into the tranche
    /// @param account The account to set the whitelist for
    /// @param allowed Whether the account is allowed to deposit
    function setWhitelist(address account, bool allowed) external restricted {
        Storage storage $ = getTrancheStorage();
        if (allowed) $.whitelist.add(account);
        else $.whitelist.remove(account);
    }

    /// @notice Check if an account is whitelisted
    /// @param account The account to check
    /// @return allowed Whether the account is whitelisted
    function whitelisted(address account) public view returns (bool allowed) {
        allowed = getTrancheStorage().whitelist.contains(account);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC4626 overrides *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice The total assets of the tranche are held in the Hub as ERC6909 tokens
    /// @return assets The total assets of the tranche
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        Storage storage $ = getTrancheStorage();
        assets = IVault($.vault).balanceOf(address(this), asset());
    }

    /// @notice The maximum number of assets that can be deposited for a receiver
    /// @param receiver The receiver of the assets
    /// @return maxAssets The maximum number of assets that can be deposited for the receiver
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxAssets)
    {
        if (whitelisted(receiver)) maxAssets = type(uint256).max;
    }

    /// @notice The maximum number of shares that can be minted for a receiver
    /// @param receiver The receiver of the shares
    /// @return maxShares The maximum number of shares that can be minted for the receiver
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 maxShares) {
        if (whitelisted(receiver)) maxShares = type(uint256).max;
    }

    /// @notice Override the _transferIn function to transfer assets internally in the Vault
    /// @param from The address of the sender
    /// @param assets The amount of assets transferred
    function _transferIn(address from, uint256 assets) internal override {
        Storage storage $ = getTrancheStorage();
        IVault($.vault).transferFrom(from, address(this), asset(), assets);
        updateIrm();
    }

    /// @notice Override the _transferOut function to transfer assets internally in the Vault
    /// @param to The address of the receiver
    /// @param assets The amount of assets transferred
    function _transferOut(address to, uint256 assets) internal override {
        Storage storage $ = getTrancheStorage();
        IVault($.vault).transfer(to, asset(), assets);
        updateIrm();
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Reward functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Update the interest rate model for the tranche
    function updateIrm() public {
        Storage storage $ = getTrancheStorage();
        IInterestRateModel($.irm).update($.market);
    }

    /// @notice Modifier to update the reward
    modifier updateReward() {
        _updateReward();
        _;
    }

    /// @notice Claim the reward for the caller
    /// @param recipient The address to send the reward to
    /// @return reward The amount of reward claimed
    function claim(address recipient) external updateReward returns (uint256 reward) {
        Storage storage $ = getTrancheStorage();
        reward = claimable(msg.sender);
        if (reward > 0) {
            $.pendingReward[msg.sender] = 0;
            $.rewardDebt[msg.sender] = $.rewardPerShare.rayMul(balanceOf(msg.sender));
            IERC20($.stablecoin).safeTransfer(recipient, reward);
            emit Claimed(msg.sender, recipient, reward);
        }
    }

    /// @notice Get the claimable reward for an address
    /// @param user The address to get the claimable reward for
    /// @return reward The amount of claimable reward
    function claimable(address user) public view returns (uint256 reward) {
        Storage storage $ = getTrancheStorage();
        reward = $.pendingReward[user] + _rewardPerShare().rayMul(balanceOf(user)) - $.rewardDebt[user];
    }

    /// @notice Update the reward
    function _updateReward() internal {
        Storage storage $ = getTrancheStorage();
        if ($.lastRewardUpdate != block.timestamp) {
            uint256 supply = activeSupply();
            if (supply > 0) {
                $.rewardPerShare += IMarket($.market).claim().rayDiv(supply);
                $.lastRewardUpdate = block.timestamp;
            }
        }
    }

    /// @notice Get the reward per share for the tranche
    /// @return rewardPerShare_ The reward per share
    function _rewardPerShare() internal view returns (uint256 rewardPerShare_) {
        Storage storage $ = getTrancheStorage();
        rewardPerShare_ = $.rewardPerShare;
        if ($.lastRewardUpdate != block.timestamp) {
            uint256 supply = activeSupply();
            if (supply > 0) rewardPerShare_ += IMarket($.market).claimable(address(this)).rayDiv(supply);
        }
    }

    /// @inheritdoc ITranche
    function market() external view returns (address) {
        return getTrancheStorage().market;
    }

    /// @notice Override the _update function to update the sender and receiver's rewards
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param amount The amount of assets transferred
    function _update(address from, address to, uint256 amount) internal override updateReward {
        Storage storage $ = getTrancheStorage();
        if (from != address(0) && from != address(this)) {
            uint256 accRewardPerShare = $.rewardPerShare;
            uint256 balance = balanceOf(from);
            $.pendingReward[from] += accRewardPerShare.rayMul(balance) - $.rewardDebt[from];
            $.rewardDebt[from] = accRewardPerShare.rayMul(balance - amount);
        }
        if (to != address(0) && to != address(this)) {
            uint256 accRewardPerShare = $.rewardPerShare;
            uint256 balance = balanceOf(to);
            $.pendingReward[to] += accRewardPerShare.rayMul(balance) - $.rewardDebt[to];
            $.rewardDebt[to] = accRewardPerShare.rayMul(balance + amount);
        }
        super._update(from, to, amount);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Async overrides *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Get the number of shares available to be redeemed
    /// @return unlocked The number of unlocked shares
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IERC7540AsyncRedeem) returns (uint256 unlocked) {
        Storage storage $ = getTrancheStorage();
        uint256 lockedShares = previewWithdraw(IMarket($.market).lockedAssets(address(this)));
        uint256 totalSupply = totalSupply();
        if (totalSupply > lockedShares) unlocked = totalSupply - lockedShares;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC165 functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Supports the ITranche interface and the ERC7540AsyncRedeem interface
    /// @param interfaceId The interface ID to check
    /// @return supported Whether the interface is supported
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC7540AsyncRedeem) returns (bool) {
        return interfaceId == type(ITranche).interfaceId || super.supportsInterface(interfaceId);
    }
}
