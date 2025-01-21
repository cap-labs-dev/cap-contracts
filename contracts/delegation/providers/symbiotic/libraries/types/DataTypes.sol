// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {
    /// @custom:storage-location erc7201:cap.storage.Network
    struct NetworkStorage {
        address middleware;
    }

    /// @custom:storage-location erc7201:cap.storage.NetworkMiddleware
    struct NetworkMiddlewareStorage {
        address network;
        address vaultRegistry;
        address oracle;
        uint48 requiredEpochDuration;
        address[] vaults;
        mapping(address => bool) registered;
        uint256[] slashingQueue;
    }

    enum SlasherType {
        INSTANT,
        VETO
    }

    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }
}
