// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAeraVault } from "../../../contracts/interfaces/IAeraVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Aera {SingleDepositorVault} stand-in: pulls on deposit and requires the
/// allowance to be fully consumed; pushes on withdraw. Auth is gated on the stablecoin instead.
contract MockAeraVault is IAeraVault {
    using SafeERC20 for IERC20;

    error Aera__UnexpectedTokenAllowance(uint256 allowance);

    /// @inheritdoc IAeraVault
    function deposit(TokenAmount[] calldata tokenAmounts) external {
        uint256 length = tokenAmounts.length;
        for (uint256 i; i < length; ++i) {
            TokenAmount calldata tokenAmount = tokenAmounts[i];
            tokenAmount.token.safeTransferFrom(msg.sender, address(this), tokenAmount.amount);
            uint256 allowance = tokenAmount.token.allowance(msg.sender, address(this));
            if (allowance != 0) revert Aera__UnexpectedTokenAllowance(allowance);
        }
    }

    /// @inheritdoc IAeraVault
    function withdraw(TokenAmount[] calldata tokenAmounts) external {
        uint256 length = tokenAmounts.length;
        for (uint256 i; i < length; ++i) {
            TokenAmount calldata tokenAmount = tokenAmounts[i];
            tokenAmount.token.safeTransfer(msg.sender, tokenAmount.amount);
        }
    }
}
