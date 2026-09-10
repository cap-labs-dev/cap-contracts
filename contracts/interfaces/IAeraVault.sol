// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAeraVault
/// @author kexley, Cap Labs
/// @notice Deposit and withdraw surface of Aera's {SingleDepositorVault}
interface IAeraVault {
    /// @notice An ERC-20 amount to move
    /// @param token The token
    /// @param amount The amount
    struct TokenAmount {
        IERC20 token;
        uint256 amount;
    }

    /// @notice Pull tokens from the caller into the vault
    /// @param tokenAmounts The tokens and amounts to deposit
    function deposit(TokenAmount[] calldata tokenAmounts) external;

    /// @notice Push tokens from the vault to the caller
    /// @param tokenAmounts The tokens and amounts to withdraw
    function withdraw(TokenAmount[] calldata tokenAmounts) external;
}
