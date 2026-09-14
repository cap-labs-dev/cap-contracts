// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UsersConfig } from "../deploy/interfaces/DeployConfigs.sol";
import { Vm } from "forge-std/Vm.sol";

/// @title Users
/// @notice Resolve deploy-time accounts from the broadcast sender and the environment
abstract contract Users {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Foundry's default script sender; refuse it so a dry-run cannot look like a real deploy
    address private constant FOUNDRY_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    /// @dev Accounts that receive protocol roles. Unset role env vars fall back to the deployer.
    /// @return users The admin and token configuration
    function _users() internal view returns (UsersConfig memory users) {
        address wallet = msg.sender;
        require(wallet != address(0) && wallet != FOUNDRY_SENDER, "pass --sender");

        users.deployer = wallet;
        users.admin = VM.envOr("ADMIN", wallet);
        users.governor = VM.envOr("GOVERNOR", wallet);
        users.keeper = VM.envOr("KEEPER", wallet);
        users.guardian = VM.envOr("GUARDIAN", wallet);
        users.liquidator = VM.envOr("LIQUIDATOR", wallet);
        users.stablecoinUnderlying = VM.envAddress("STABLECOIN_UNDERLYING");
        users.reserveVault = VM.envOr("RESERVE_VAULT", address(0));
    }
}
