// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540AsyncRedeem } from "../interfaces/IERC7540AsyncRedeem.sol";

/// @title ERC7540AsyncRedeem Storage Utils
/// @author kexley, Cap Labs
/// @notice Storage utilities for ERC7540AsyncRedeem
abstract contract ERC7540AsyncRedeemStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.ERC7540AsyncRedeem")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540ASYNCREDEEM_STORAGE_LOCATION =
        0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    /// @dev Get ERC7540AsyncRedeem storage
    /// @return $ Storage pointer
    function getERC7540AsyncRedeemStorage()
        internal
        pure
        returns (IERC7540AsyncRedeem.ERC7540AsyncRedeemStorage storage $)
    {
        assembly {
            $.slot := ERC7540ASYNCREDEEM_STORAGE_LOCATION
        }
    }
}
