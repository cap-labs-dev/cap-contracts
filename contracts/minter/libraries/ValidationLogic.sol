// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRegistry } from "../../interfaces/IRegistry.sol";

import { Errors } from "./helpers/Errors.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Validation Logic
/// @author kexley, @capLabs
/// @notice Validation logic for cap token minting/burning
library ValidationLogic {

    /// @notice Validate if a cap token can be redeemed
    /// @param _capToken Token to redeem
    /// @param _deadline Deadline for redeem to take place
    function validateRedeem(address registry, address _capToken, uint256 _deadline) external view {
        require(IRegistry(registry).supportedCToken(_capToken), Errors.ASSET_NOT_LISTED);
        require(_deadline >= block.timestamp, Errors.PAST_DEADLINE);
    }

    /// @notice Validate a mint or burn
    /// @param params Parameters to check
    /// @return mint True if mint action or false if burning
    function validateSwap(DataTypes.ValidateSwapParams memory params) external view returns (bool mint) {
        IRegistry registry = IRegistry(params.registry);
        mint = registry.supportedCToken(params.tokenOut) 
            && registry.basketSupportsAsset(params.tokenOut, params.tokenIn);

        bool burn;
        if (!mint) {
            burn = registry.supportedCToken(params.tokenIn) 
                && registry.basketSupportsAsset(params.tokenIn, params.tokenOut);
        }

        require(mint || burn, Errors.PAIR_NOT_SUPPORTED);
        require(params.deadline >= block.timestamp, Errors.PAST_DEADLINE);
    }

    /// @notice Validate an amount against the minimum
    /// @param _minAmount Minimum acceptable output
    /// @param _actualAmount Actual amount outputted
    function validateMinAmount(uint256 _minAmount, uint256 _actualAmount) external pure {
        require(_actualAmount >= _minAmount, Errors.TOO_LITTLE_OUTPUT);
    }
}
