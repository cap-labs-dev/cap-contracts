// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library DataTypes {
    struct PreMainnetVaultStorage {
        /// @notice Underlying asset
        IERC20 asset;
        /// @notice Maximum end timestamp for the campaign
        uint256 maxCampaignEnd;
        /// @notice Decimals of the token
        uint8 decimals;
        /// @dev Transfer enabled flag after campaign ends
        bool allowTransferBeforeCampaignEnd;
    }

    struct OAppMessengerStorage {
        /// @notice Destination EID for the LayerZero bridge
        uint32 dstEid;
        /// @notice Decimals of the token
        uint8 decimals;
        /// @notice Gas limit for the LayerZero bridge
        uint128 lzReceiveGas;
    }
}