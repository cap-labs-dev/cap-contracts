// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @title IOAppMessenger
/// @author @capLabs
/// @notice Interface for OAppMessenger contract
interface IOAppMessenger {
    /// @notice Storage for OAppMessenger contract
    /// @dev Destination EID for the LayerZero bridge
    /// @dev Decimals of the token
    struct OAppMessengerStorage {
        uint32 dstEid;
        uint8 decimals;
    }

    /// @notice Quote the fee for the LayerZero bridge
    /// @param _amountLD Amount of asset in local decimals
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    /// @return fee Fee for the LayerZero bridge
    function quote(uint256 _amountLD, address _destReceiver) external view returns (MessagingFee memory fee);

    /// @notice Retrieves the shared decimals of the OFT.
    /// @return The shared decimals of the OFT.
    function sharedDecimals() external view returns (uint8);
}
