// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPreMainnetVault } from "../interfaces/IPreMainnetVault.sol";
import { PreMainnetVaultStorageUtils } from "../storage/PreMainnetVaultStorageUtils.sol";
import { OAppCoreUpgradeable, OAppMessenger } from "./OAppMessenger.sol";

/// @title PreMainnetVault
/// @author @capLabs
/// @notice Vault for pre-mainnet campaign
/// @dev Underlying asset is deposited on this contract and LayerZero is used to bridge across a
/// minting message to the testnet. The campaign has a maximum timestamp after which transfers are
/// enabled to prevent the owner from unduly locking assets.
contract PreMainnetVault is
    UUPSUpgradeable,
    IPreMainnetVault,
    ERC20PermitUpgradeable,
    OAppMessenger,
    PreMainnetVaultStorageUtils
{
    using SafeERC20 for IERC20Metadata;

    /// @dev Initialize the token with the LayerZero endpoint
    /// @param _lzEndpoint LayerZero endpoint
    constructor(address _lzEndpoint) OAppMessenger(_lzEndpoint) {
        _disableInitializers();
    }

    /// @notice Initialize the token with the underlying asset and bridge info
    /// @param _asset Underlying asset
    /// @param _dstEid Destination lz EID
    /// @param _maxCampaignLength Max campaign length in seconds
    function initialize(address _asset, uint32 _dstEid, uint256 _maxCampaignLength) external initializer {
        __UUPSUpgradeable_init();
        __ERC20_init("Boosted cUSD", "bcUSD");
        __ERC20Permit_init("Boosted cUSD");
        __Ownable_init(msg.sender);
        __OAppMessenger_init(_dstEid, IERC20Metadata(_asset).decimals());

        PreMainnetVaultStorage storage $ = getPreMainnetVaultStorage();

        $.asset = IERC20Metadata(_asset);
        $.maxCampaignEnd = block.timestamp + _maxCampaignLength;
    }

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param _amount Amount of underlying asset to deposit
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    function deposit(uint256 _amount, address _destReceiver) external payable {
        if (_amount == 0) revert ZeroAmount();

        getPreMainnetVaultStorage().asset.safeTransferFrom(msg.sender, address(this), _amount);

        _mint(msg.sender, _amount);

        _sendMessage(_destReceiver, _amount);

        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraw underlying asset after campaign ends
    /// @param _amount Amount of underlying asset to withdraw
    /// @param _receiver Receiver of the withdrawn underlying assets
    function withdraw(uint256 _amount, address _receiver) external {
        _burn(msg.sender, _amount);

        getPreMainnetVaultStorage().asset.safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Override decimals to return decimals of underlying asset
    /// @return decimals Asset decimals
    function decimals() public view override returns (uint8) {
        return getPreMainnetVaultStorage().asset.decimals();
    }

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() public view returns (bool enabled) {
        PreMainnetVaultStorage storage $ = getPreMainnetVaultStorage();
        enabled = $.unlocked || block.timestamp > $.maxCampaignEnd;
    }

    /// @notice Enable transfers before campaign ends
    function enableTransfer() external onlyOwner {
        getPreMainnetVaultStorage().unlocked = true;
        emit TransferEnabled();
    }

    /// @dev Override _update to disable transfer before campaign ends
    /// @param _from From address
    /// @param _to To address
    /// @param _value Amount to transfer
    function _update(address _from, address _to, uint256 _value) internal override {
        if (!transferEnabled() && _from != address(0)) revert TransferNotEnabled();
        super._update(_from, _to, _value);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
