// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { DataTypes } from "./libraries/DataTypes.sol";
import { PreMainnetVaultStorage } from "./libraries/PreMainnetVaultStorage.sol";
import { OAppMessenger } from "./OAppMessenger.sol";

import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PreMainnetVault
/// @author @capLabs
/// @notice Vault for pre-mainnet campaign
/// @dev Underlying asset is deposited on this contract and LayerZero is used to bridge across a
/// minting message to the testnet. The campaign has a maximum timestamp after which transfers are 
/// enabled to prevent the owner from unduly locking assets.
contract PreMainnetVault is ERC20PermitUpgradeable, OAppMessenger {
    using SafeERC20 for IERC20;

    /// @dev Zero amounts are not allowed for minting
    error ZeroAmount();

    /// @dev Transfers not yet enabled
    error TransferNotEnabled();

    /// @dev Deposit underlying asset
    event Deposit(address indexed user, uint256 amount);

    /// @dev Withdraw underlying asset
    event Withdraw(address indexed user, uint256 amount);

    /// @dev Transfers enabled
    event TransferEnabled();

    /// @dev OAppCore sets the endpoint as an immutable variable
    /// @param _lzEndpoint Local layerzero endpoint
    constructor(address _lzEndpoint) OAppMessenger(_lzEndpoint) {}

    /// @notice Initialize
    /// @param _asset Underlying asset
    /// @param _dstEid Destination lz EID
    /// @param _maxCampaignLength Max campaign length in seconds
    function initialize(address _asset, uint32 _dstEid, uint256 _maxCampaignLength) external initializer {
        string memory _name = string.concat(string.concat("Pre-Mainnet Vault ", IERC20Metadata(_asset).name()));
        string memory _symbol = string.concat("pm", IERC20Metadata(_asset).symbol());
        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __OAppMessenger_init(msg.sender, _dstEid, assetDecimals);

        DataTypes.PreMainnetVaultStorage storage $ = PreMainnetVaultStorage.get();
        $.asset = IERC20(_asset);
        $.maxCampaignEnd = block.timestamp + _maxCampaignLength;
        $.decimals = assetDecimals;
    }

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param _amount Amount of underlying asset to deposit
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    function deposit(uint256 _amount, address _destReceiver) external payable {
        if (_amount == 0) revert ZeroAmount();

        PreMainnetVaultStorage.get().asset.safeTransferFrom(msg.sender, address(this), _amount);

        _mint(msg.sender, _amount);

        _sendMessage(_destReceiver, _amount);

        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraw underlying asset after campaign ends
    /// @param _amount Amount of underlying asset to withdraw
    /// @param _receiver Receiver of the withdrawn underlying assets
    function withdraw(uint256 _amount, address _receiver) external {
        _burn(msg.sender, _amount);

        PreMainnetVaultStorage.get().asset.safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Override decimals to return decimals of underlying asset
    /// @return decimals Asset decimals
    function decimals() public view override returns (uint8) {
        return PreMainnetVaultStorage.get().decimals;
    }

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() public view returns (bool enabled) {
        DataTypes.PreMainnetVaultStorage storage $ = PreMainnetVaultStorage.get();
        enabled = $.allowTransferBeforeCampaignEnd || block.timestamp > $.maxCampaignEnd;
    }

    /// @notice Enable transfers after campaign ends
    function enableTransfer() external onlyOwner {
        PreMainnetVaultStorage.get().allowTransferBeforeCampaignEnd = true;
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
}
