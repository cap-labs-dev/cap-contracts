// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct PreMainnetVaultStorage {
    /// @notice Underlying asset
    IERC20 asset;
    /// @notice Maximum end timestamp for the campaign
    uint256 maxCampaignEnd;
    /// @notice Decimals of the token
    uint8 decimals;
    /// @notice Destination EID for the LayerZero bridge
    uint32 dstEid;
    /// @dev Transfer enabled flag after campaign ends
    bool allowTransferBeforeCampaignEnd;
    /// @notice Gas limit for the LayerZero bridge
    uint128 lzReceiveGas;
}

/// @title Network storage pointer
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
library PreMainnetVaultStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.PreMainnetVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PreMainnetVaultStorageLocation =
        0xa32052a65e980f128858ffb78b2c1d6bb1e7ecda0ba46f7b16ec146539e21e00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function get() internal pure returns (PreMainnetVaultStorage storage $) {
        assembly {
            $.slot := PreMainnetVaultStorageLocation
        }
    }
}
