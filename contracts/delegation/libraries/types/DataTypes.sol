// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {
    /// @custom:storage-location erc7201:cap.storage.Delegation
    struct DelegationStorage {
        address[] providers;
        address[] agents;
        mapping(address => AgentData) agentData;
        address oracle;
    }

    struct AgentData {
        uint256 ltv;
        uint256 liquidationThreshold;
    }
}
