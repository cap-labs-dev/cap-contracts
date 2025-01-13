// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PreMainnetVault
/// @notice Vault for pre-mainnet campaign
/// @dev Campaign has a maximum timestamp after which transfers are enabled
contract PreMainnetVault is ERC20Permit, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Underlying asset
    IERC20 public asset;

    /// @notice Maximum end timestamp for the campaign
    uint256 public maxCampaignEnd;

    /// @notice Decimals of the token
    uint8 private _decimals;

    /// @dev Transfer enabled flag after campaign ends
    bool private _transferEnabled;

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

    /// @dev Deploy the contract with the underlying asset, deployer becomes owner
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _asset Underlying asset
    /// @param _maxCampaignLength Max campaign length in seconds
    constructor(
        string memory _name,
        string memory _symbol,
        address _asset,
        uint256 _maxCampaignLength
    ) 
        ERC20(_name, _symbol)
        ERC20Permit(_name)
        Ownable(msg.sender)
    {
        asset = IERC20(_asset);
        maxCampaignEnd = block.timestamp + _maxCampaignLength;
        _decimals = IERC20Metadata(_asset).decimals();
    }

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param _amount Amount of underlying asset to deposit
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    function deposit(uint256 _amount, address _destReceiver) external {
        if (_amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), _amount);

        _mint(msg.sender, _amount);

        /// todo: lz bridge logic to mint on testnet 
        /// Receiver could be different on the testnet (multi-sigs)
        _destReceiver;

        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraw underlying asset after campaign ends
    /// @param _amount Amount of underlying asset to withdraw
    /// @param _receiver Receiver of the withdrawn underlying assets
    function withdraw(uint256 _amount, address _receiver) external {
        _burn(msg.sender, _amount);

        asset.safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Enable transfers after campaign ends
    function enableTransfer() external onlyOwner {
        _transferEnabled = true;

        emit TransferEnabled();
    }

    /// @notice Override decimals to return decimals of underlying asset
    /// @return decimals Asset decimals
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() public view returns (bool enabled) {
        enabled = _transferEnabled || block.timestamp > maxCampaignEnd;
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
