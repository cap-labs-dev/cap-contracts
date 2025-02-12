// SPDX-License-Identifier: BUSL-1.1
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
        uint256 feeAllowed;
        mapping(address => address) stakerRewarders; // vault => stakerRewarder
        mapping(address => address[]) vaults; // agent => vault[]
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
