// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ERC4626Upgradeable,
    ERC7540AsyncRedeem,
    IERC4626,
    IERC7540AsyncRedeem
} from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IInverseInterestRateModel } from "../interfaces/IInverseInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IRewarder } from "../interfaces/IRewarder.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { UnderwriterStorageUtils } from "../storage/UnderwriterStorageUtils.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Underwriter
/// @author kexley
/// @notice Underwriter is a ERC4626 vault that allows users to deposit via the Hub ERC6909 tokens. cUSD rewards are earned from
/// underwriting the market.
contract Underwriter is IUnderwriter, ERC7540AsyncRedeem, OwnableUpgradeable, UnderwriterStorageUtils {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @notice Initialize the underwriter
    /// @param _marketId The id of the market
    /// @param _asset The asset to underwrite
    /// @param _manager The manager of the underwriter
    /// @param _name The name of the underwriter
    /// @param _symbol The symbol of the underwriter
    /// @param _vault The vault for the underwriter
    /// @param _rewarder The rewarder for the underwriter
    /// @param _irm The interest rate model for the underwriter
    function initialize(
        bytes32 _marketId,
        string memory _name,
        string memory _symbol,
        address _asset,
        address _manager,
        address _vault,
        address _rewarder,
        address _irm
    ) external initializer {
        Storage storage $ = getUnderwriterStorage();
        $.marketId = _marketId;
        __Ownable_init(_manager);
        __ERC7540AsyncRedeem_init(IERC20(_asset), _name, _symbol, hex"");
        $.vault = _vault;
        $.rewarder = _rewarder;
        $.irm = _irm;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Slash functions *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Slash the underwriter's assets
    /// @param assets The amount of assets to slash
    /// @return slashedAssets The amount of assets slashed
    function slash(uint256 assets, address recipient) external returns (uint256 slashedAssets) {
        Storage storage $ = getUnderwriterStorage();
        if (msg.sender != address($.vault)) revert Unauthorized();
        slashedAssets = Math.min(assets, totalAssets());
        IVault($.vault).withdraw(asset(), slashedAssets, recipient);
        updateIRM();
    }

    /// @notice Update the interest rate model for the underwriter
    function updateIRM() public {
        Storage storage $ = getUnderwriterStorage();
        IInverseInterestRateModel($.irm).update($.marketId);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Whitelist functions ***************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Set the whitelist for a depositor into the underwriter
    /// @param account The account to set the whitelist for
    /// @param allowed Whether the account is allowed to deposit
    function setWhitelist(address account, bool allowed) external onlyOwner {
        Storage storage $ = getUnderwriterStorage();
        if (allowed) $.whitelist.add(account);
        else $.whitelist.remove(account);
    }

    /// @notice Check if an account is whitelisted
    /// @param account The account to check
    /// @return allowed Whether the account is whitelisted
    function whitelisted(address account) public view returns (bool allowed) {
        allowed = getUnderwriterStorage().whitelist.contains(account);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC4626 overrides *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice The total assets of the underwriter are held in the Hub as ERC6909 tokens
    /// @return assets The total assets of the underwriter
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        Storage storage $ = getUnderwriterStorage();
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

    /// @notice Override the _transferIn function to transfer assets internally in the Hub
    /// @param from The address of the sender
    /// @param assets The amount of assets transferred
    function _transferIn(address from, uint256 assets) internal override {
        Storage storage $ = getUnderwriterStorage();
        IVault($.vault).transferFrom(from, address(this), asset(), assets);
        updateIRM();
    }

    /// @notice Override the _transferOut function to transfer assets internally in the Vault
    /// @param to The address of the receiver
    /// @param assets The amount of assets transferred
    function _transferOut(address to, uint256 assets) internal override {
        Storage storage $ = getUnderwriterStorage();
        IVault($.vault).transfer(to, asset(), assets);
        updateIRM();
    }

    /// @notice Override the _update function to update the sender and receiver's cUSD rewards
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param amount The amount of assets transferred
    function _update(address from, address to, uint256 amount) internal override {
        Storage storage $ = getUnderwriterStorage();
        if (from != address(0) && from != address(this)) {
            IRewarder($.rewarder).decreaseRewardDebt($.marketId, from, amount);
        }
        if (to != address(0) && to != address(this)) {
            IRewarder($.rewarder).increaseRewardDebt($.marketId, to, amount);
        }
        super._update(from, to, amount);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Async overrides *******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Get the number of shares available to be redeemed
    /// @return unlocked The number of unlocked shares
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IERC7540AsyncRedeem) returns (uint256 unlocked) {
        Storage storage $ = getUnderwriterStorage();
        uint256 lockedShares = previewWithdraw(ILender($.lender).lockedAssets($.marketId, address(this)));
        uint256 totalSupply = totalSupply();
        if (totalSupply > lockedShares) unlocked = totalSupply - lockedShares;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC165 functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Supports the IUnderwriter interface and the ERC7540AsyncRedeem interface
    /// @param interfaceId The interface ID to check
    /// @return supported Whether the interface is supported
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC7540AsyncRedeem) returns (bool) {
        return interfaceId == type(IUnderwriter).interfaceId || super.supportsInterface(interfaceId);
    }
}
