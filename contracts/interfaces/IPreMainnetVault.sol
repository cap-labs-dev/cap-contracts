// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IPreMainnetVault
/// @author @capLabs
/// @notice Interface for PreMainnetVault contract
interface IPreMainnetVault {
    /// @notice Storage for PreMainnetVault contract
    /// @dev Underlying asset
    /// @dev Max campaign end
    /// @dev Unlocked
    struct PreMainnetVaultStorage {
        IERC20Metadata asset;
        uint256 maxCampaignEnd;
        bool unlocked;
    }

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

    /// @notice Initialize the PreMainnetVault contract
    /// @param asset Underlying asset
    /// @param dstEid Destination EID
    /// @param maxCampaignLength Max campaign length
    function initialize(address asset, uint32 dstEid, uint256 maxCampaignLength) external;

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param amount Amount of underlying asset to deposit
    /// @param destReceiver Destination receiver
    function deposit(uint256 amount, address destReceiver) external payable;

    /// @notice Withdraw underlying asset from PreMainnetVault
    /// @param amount Amount of underlying asset to withdraw
    /// @param receiver Receiver of the underlying asset
    function withdraw(uint256 amount, address receiver) external;

    /// @notice Enable transfers before campaign ends
    function enableTransfer() external;

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() external view returns (bool enabled);
}
