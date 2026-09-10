// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title CapRoles
/// @author kexley, Cap Labs
/// @notice Protocol-wide role identifiers for OpenZeppelin AccessManager
library CapRoles {
    /// @dev Upgrades and critical infrastructure (OpenZeppelin default admin role)
    uint64 internal constant ADMIN = 0;

    /// @dev Emergency actions — pause, tighten risk parameters
    uint64 internal constant GUARDIAN = 1;

    /// @dev Economic policy and operator onboarding
    uint64 internal constant GOVERNOR = 2;

    /// @dev Routine operations — deploy instances, maintenance calls
    uint64 internal constant KEEPER = 3;

    /// @dev Markets — mint/burn cUSD, slash and fund tranches, drive the rate model
    uint64 internal constant MARKET = 4;

    /// @dev Registry contract — admin of dynamically assigned operator roles
    uint64 internal constant REGISTRY = 5;

    /// @dev Permissioned liquidation of unhealthy markets
    uint64 internal constant LIQUIDATOR = 6;

    /// @dev First role id assigned by {Registry-assignOperator}
    uint64 internal constant FIRST_OPERATOR_ROLE = 100;
}
