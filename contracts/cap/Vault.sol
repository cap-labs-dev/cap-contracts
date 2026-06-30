// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    ERC6909TokenSupplyUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC6909/extensions/ERC6909TokenSupplyUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IVault } from "../interfaces/IVault.sol";
import { AssetId } from "../utils/AssetId.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Vault
/// @author kexley
/// @notice The Vault is a contract that allows users to deposit and withdraw ERC20 assets.
contract Vault is IVault, AccessManagedUpgradeable, ERC6909TokenSupplyUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using AssetId for address;

    /// @notice Initialize the Vault
    /// @param _authority The authority address
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    /// @notice Deposits an asset into the Vault
    /// @param _asset The asset to deposit
    /// @param _amount The amount of asset to deposit
    /// @param _recipient The recipient of the asset
    function deposit(address _asset, uint256 _amount, address _recipient) external {
        _mint(_recipient, _asset.toId(), _amount);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Withdraws an asset from the Vault
    /// @param _asset The asset to withdraw
    /// @param _amount The amount of asset to withdraw
    function withdraw(address _asset, uint256 _amount, address _recipient) external {
        _burn(msg.sender, _asset.toId(), _amount);
        IERC20(_asset).safeTransfer(_recipient, _amount);
    }

    /// @notice Get the balance of an asset for an owner
    /// @param _owner The owner of the asset
    /// @param _asset The asset to get the balance of
    /// @return balance The balance of the asset for the owner
    function balanceOf(address _owner, address _asset) external view returns (uint256 balance) {
        balance = balanceOf(_owner, _asset.toId());
    }

    /// @notice Transfer an asset from one address to another
    /// @param _from The address to transfer from
    /// @param _to The address to transfer to
    /// @param _asset The asset to transfer
    /// @param _amount The amount of asset to transfer
    function transferFrom(address _from, address _to, address _asset, uint256 _amount) external {
        transferFrom(_from, _to, _asset.toId(), _amount);
    }

    /// @notice Transfer an asset to an address
    /// @param _to The address to transfer to
    /// @param _asset The asset to transfer
    /// @param _amount The amount of asset to transfer
    function transfer(address _to, address _asset, uint256 _amount) external {
        transfer(_to, _asset.toId(), _amount);
    }

    /// @notice Get the id of an asset
    /// @param _asset The asset to get the id for
    /// @return assetId The id of the asset
    function id(address _asset) external pure returns (uint256 assetId) {
        assetId = AssetId.toId(_asset);
    }

    /// @notice Get the asset address of an id
    /// @param _id The id to get the asset address for
    /// @return assetAddress The asset address of the id
    function asset(uint256 _id) external pure returns (address assetAddress) {
        assetAddress = AssetId.toAsset(_id);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
