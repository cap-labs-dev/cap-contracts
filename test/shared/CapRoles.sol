// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title CapRoles
/// @notice Shared role IDs for Cap protocol tests. Registry-internal roles (guardian/keeper/minter)
/// match `Registry.sol`; manager and borrower are test-specific IDs passed into `createMarket`.
library CapRoles {
    uint64 internal constant ADMIN = 0;
    uint64 internal constant GUARDIAN = 1;
    uint64 internal constant KEEPER = 2;
    uint64 internal constant MINTER = 3;
    uint64 internal constant MANAGER = 4;
    uint64 internal constant BORROWER = 5;
}
