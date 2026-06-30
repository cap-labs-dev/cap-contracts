// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC6909TokenSupply } from "@openzeppelin/contracts/interfaces/IERC6909.sol";

/// @title IVault
/// @author kexley, Cap Labs
/// @notice Interface for the collateral vault (ERC6909)
interface IVault is IERC6909TokenSupply {
    /// @notice Deposit an ERC20 asset and mint the corresponding ERC6909 balance
    /// @param asset The ERC20 asset to deposit
    /// @param amount The amount to deposit
    /// @param recipient The address to receive the minted balance
    function deposit(address asset, uint256 amount, address recipient) external;

    /// @notice Burn ERC6909 balance and withdraw the underlying ERC20 asset
    /// @param asset The ERC20 asset to withdraw
    /// @param amount The amount to withdraw
    /// @param recipient The address to receive the withdrawn tokens
    function withdraw(address asset, uint256 amount, address recipient) external;

    /// @notice Transfer an asset from one address to another
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param asset The asset to transfer
    /// @param amount The amount of asset to transfer
    function transferFrom(address from, address to, address asset, uint256 amount) external;

    /// @notice Transfer an asset to an address
    /// @param to The address to transfer to
    /// @param asset The asset to transfer
    /// @param amount The amount of asset to transfer
    function transfer(address to, address asset, uint256 amount) external;

    /// @notice Get the balance of an asset for an address
    /// @param owner The address to get the balance of
    /// @param asset The asset to get the balance of
    /// @return balance The balance of the asset for the address
    function balanceOf(address owner, address asset) external view returns (uint256 balance);

    /// @notice Get the ERC6909 token id for an asset address
    /// @param asset The ERC20 asset address
    /// @return id The token id (lower 160 bits of the address)
    function id(address asset) external view returns (uint256 id);

    /// @notice Get the ERC20 asset address for a token id
    /// @param id The ERC6909 token id
    /// @return asset The ERC20 asset address
    function asset(uint256 id) external view returns (address asset);
}
