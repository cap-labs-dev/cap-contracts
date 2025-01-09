// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVaultDataProvider } from "../../interfaces/IVaultDataProvider.sol";

import { Errors } from "./helpers/Errors.sol";
import { DataTypes } from "./types/DataTypes.sol";

/// @title Validation Logic
/// @author kexley, @capLabs
/// @notice Validation logic for cap token minting/burning
library ValidationLogic {
    /// @notice Validate if a cap token can be redeemed
    /// @param _vault Vault of a cap token
    /// @param _deadline Deadline for redeem to take place
    function validateRedeem(address _vault, uint256 _deadline) external view {
        require(_vault != address(0), Errors.ASSET_NOT_LISTED);
        require(_deadline >= block.timestamp, Errors.PAST_DEADLINE);
    }

    /// @notice Validate a mint or burn
    /// @param params Parameters to check
    /// @return mint True if mint action or false if burning
    function validateSwap(DataTypes.ValidateSwapParams memory params) external view returns (bool mint) {
        address vaultOut = IVaultDataProvider(params.vaultDataProvider).vault(params.tokenOut);

        if (vaultOut != address(0)) {
            IVaultDataProvider.VaultData memory tokenOutVaultData 
                = IVaultDataProvider(params.vaultDataProvider).vaultData(vaultOut);

            uint256 length = tokenOutVaultData.assets.length;
            for (uint256 i; i < length; ++i) {
                if (tokenOutVaultData.assets[i] == params.tokenIn) {
                    mint = true;
                    break;
                }
            }
        }

        bool burn;
        if (!mint) {
            address vaultIn = IVaultDataProvider(params.vaultDataProvider).vault(params.tokenIn);
            if (vaultIn != address(0)) {
                IVaultDataProvider.VaultData memory tokenInVaultData 
                    = IVaultDataProvider(params.vaultDataProvider).vaultData(vaultIn);

                uint256 length = tokenInVaultData.assets.length;
                for (uint256 i; i < length; ++i) {
                    if (tokenInVaultData.assets[i] == params.tokenOut) {
                        burn = true;
                        break;
                    }
                }
            }
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
