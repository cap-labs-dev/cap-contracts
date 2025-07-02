// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IMintableERC20
/// @author kexley, Cap Labs
/// @notice Interface for mintable ERC20
interface IMintableERC20 {
    /// @dev Mintable ERC20 storage
    /// @param name Name of the token
    /// @param symbol Symbol of the token
    /// @param decimals Decimals of the token
    /// @param balances Balances of the token
    /// @param totalSupply Total supply of the token
    struct MintableERC20Storage {
        string name;
        string symbol;
        uint8 decimals;
        mapping(address => uint256) balances;
        uint256 totalSupply;
    }

    /// @dev Operation not supported
    error OperationNotSupported();
}
