// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DataTypes} from "../libraries/types/DataTypes.sol";

/// @title Lender Storage
/// @author kexley, @capLabs
/// @notice Storage for the Lender
contract LenderStorage {
    /// @dev Address provider for all contracts
    address internal ADDRESS_PROVIDER;

    /// @dev Data mapping for each reserve
    mapping(address => DataTypes.ReserveData) internal _reservesData;

    /// @dev Mapping of every reserve id to an address
    mapping(uint256 => address) internal _reservesList;

    /// @dev Bitwise map of each agent's borrowed markets
    mapping(address => DataTypes.AgentConfigurationMap) internal _agentConfig;

    /// @dev Total count of initialized reserves, including dropped ones
    uint16 internal _reservesCount;
}
