// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IBeaconFactory
/// @author kexley, Cap Labs
/// @notice Interface for beacon proxy factories
interface IBeaconFactory {
    function create(bytes memory data) external returns (address proxy);
}
