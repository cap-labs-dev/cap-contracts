// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library DataTypes {
    /// @custom:storage-location erc7201:cap.storage.Delegation
    struct DelegationStorage {
        address[] agents;
        mapping(address => AgentData) agentData;
        mapping(address => address[]) networks;
        address oracle;
    }

    struct AgentData {
        uint256 ltv;
        uint256 liquidationThreshold;
    }
}
