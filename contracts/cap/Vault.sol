// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

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
/// @author kexley, Cap Labs
/// @notice The Vault is a contract that allows users to deposit and withdraw ERC20 assets.
contract Vault is IVault, AccessManagedUpgradeable, ERC6909TokenSupplyUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using AssetId for address;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IVault
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    /// @inheritdoc IVault
    function deposit(address _asset, uint256 _amount, address _recipient) external {
        _mint(_recipient, _asset.toId(), _amount);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @inheritdoc IVault
    function withdraw(address _asset, uint256 _amount, address _recipient) external {
        _burn(msg.sender, _asset.toId(), _amount);
        IERC20(_asset).safeTransfer(_recipient, _amount);
    }

    /// @inheritdoc IVault
    function balanceOf(address _owner, address _asset) external view returns (uint256 balance) {
        balance = balanceOf(_owner, _asset.toId());
    }

    /// @inheritdoc IVault
    function transferFrom(address _from, address _to, address _asset, uint256 _amount) external {
        transferFrom(_from, _to, _asset.toId(), _amount);
    }

    /// @inheritdoc IVault
    function transfer(address _to, address _asset, uint256 _amount) external {
        transfer(_to, _asset.toId(), _amount);
    }

    /// @inheritdoc IVault
    function id(address _asset) external pure returns (uint256 assetId) {
        assetId = AssetId.toId(_asset);
    }

    /// @inheritdoc IVault
    function asset(uint256 _id) external pure returns (address assetAddress) {
        assetAddress = AssetId.toAsset(_id);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
