// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./libraries/types/DataTypes.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract LenderStorage {
    address internal ADDRESS_PROVIDER;
    mapping(address => DataTypes.ReserveData) internal _reservesData;
    mapping(uint256 => address) internal _reservesList;
    mapping(address => DataTypes.AgentConfigurationMap) internal _agentConfig;
    uint16 internal _reservesCount;
}
