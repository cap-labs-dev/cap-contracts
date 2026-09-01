// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapRoles as CapRolesLib } from "../../contracts/utils/CapRoles.sol";

/// @title CapRoles
/// @notice Test helpers wrapping protocol role ids from {CapRolesLib}.
library CapRoles {
    uint64 internal constant ADMIN = CapRolesLib.ADMIN;
    uint64 internal constant GUARDIAN = CapRolesLib.GUARDIAN;
    uint64 internal constant KEEPER = CapRolesLib.KEEPER;
    uint64 internal constant MINTER = CapRolesLib.MINTER;
    uint64 internal constant GOVERNOR = CapRolesLib.GOVERNOR;
    uint64 internal constant REGISTRY = CapRolesLib.REGISTRY;
    uint64 internal constant LIQUIDATOR = CapRolesLib.LIQUIDATOR;
    uint64 internal constant FIRST_OPERATOR_ROLE = CapRolesLib.FIRST_OPERATOR_ROLE;
}
