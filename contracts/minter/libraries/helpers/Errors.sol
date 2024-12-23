// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Errors library
/// @author kexley, @capLabs
/// @notice Defines the error messages emitted by the minter
library Errors {
    string public constant ASSET_NOT_LISTED = '1'; // 'The asset is not listed'
    string public constant PAST_DEADLINE = '2'; // 'Past the deadline'
    string public constant PAIR_NOT_SUPPORTED = '3'; // 'Token pair is not supported to swap'
    string public constant TOO_LITTLE_OUTPUT = '4'; // 'Too little output received'
}
