// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICapToken } from "../../interfaces/ICapToken.sol";
import { IVault } from "../../interfaces/IVault.sol";

import { ValidationLogic } from "./ValidationLogic.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Mint Burn Logic
/// @author kexley, @capLabs
/// @notice Mint/Burn logic for exchanging underlying assets with cap tokens
library MintBurnLogic {
    using SafeERC20 for IERC20;

    /// @dev Swap made
    event Swap(
        address indexed sender, address indexed to, address asset, address capToken, uint256 amountIn, uint256 amountOut
    );

    /// @dev Redeem made
    event Redeem(address indexed sender, address indexed to, address tokenIn, uint256 amountIn, uint256[] amountOuts);

    /// @notice Mint a cap token in exchange for an underlying asset
    /// @param params Parameters for minting
    function mint(DataTypes.MintBurnParams memory params) external {
        ICapToken(params.capToken).mint(params.receiver, params.amountOut);

        IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.asset).forceApprove(params.vault, params.amountIn);
        IVault(params.vault).deposit(params.asset, params.amountIn);

        emit Swap(msg.sender, params.receiver, params.asset, params.capToken, params.amountIn, params.amountOut);
    }

    /// @notice Burn a cap token in exchange for an underlying asset
    /// @param params Parameters for burning
    function burn(DataTypes.MintBurnParams memory params) external {
        ICapToken(params.capToken).burn(msg.sender, params.amountIn);

        IVault(params.vault).withdraw(params.asset, params.amountOut, params.receiver);

        emit Swap(msg.sender, params.receiver, params.asset, params.capToken, params.amountIn, params.amountOut);
    }

    /// @notice Redeem a cap token in exchange for proportional weighting of underlying assets
    /// @param params Parameters for redeeming
    function redeem(DataTypes.RedeemParams memory params) external {
        ICapToken(params.capToken).burn(msg.sender, params.amount);

        uint256 amountLength = params.amountOuts.length;
        for (uint256 i; i < amountLength; ++i) {
            ValidationLogic.validateMinAmount(params.minAmountOuts[i], params.amountOuts[i]);
            IVault(params.vault).withdraw(params.assets[i], params.amountOuts[i], params.receiver);
        }

        emit Redeem(msg.sender, params.receiver, params.capToken, params.amount, params.amountOuts);
    }
}
