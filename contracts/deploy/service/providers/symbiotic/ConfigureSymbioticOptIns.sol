// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../../../access/AccessControl.sol";

import { SymbioticNetwork } from "../../../../delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from "../../../../delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { InfraConfig, UsersConfig } from "../../../interfaces/DeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkAdapterParams,
    SymbioticVaultConfig
} from "../../../interfaces/SymbioticsDeployConfigs.sol";
import { ProxyUtils } from "../../../utils/ProxyUtils.sol";
import { SymbioticUtils } from "../../../utils/SymbioticUtils.sol";

import { TestUsersConfig } from "../../../../../test/deploy/interfaces/TestDeployConfig.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";

import { SymbioticAddressbook } from "../../../utils/SymbioticUtils.sol";

import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { IOperatorRegistry } from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";
import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";
import { console } from "forge-std/console.sol";

contract ConfigureSymbioticOptIns {
    /// OPT-INS
    // https://docs.symbiotic.fi/modules/registries#opt-ins-in-symbiotic

    // 1. Operator to Vault Opt-in
    // Operators use the VaultOptInService to opt into specific vaults. This allows them to receive stake allocations from these vaults.
    function _agentOptInToSymbioticVault(SymbioticAddressbook memory addressbook, SymbioticVaultConfig memory vault)
        internal
    {
        IOptInService(addressbook.services.vaultOptInService).optIn(vault.vault);
    }

    // 2. Operator to Network Opt-in
    // Through the NetworkOptInService, operators can opt into networks they wish to work with. This signifies their willingness to provide services to these networks.
    function _agentOptInToSymbioticNetwork(
        SymbioticAddressbook memory addressbook,
        SymbioticNetworkAdapterConfig memory networkAdapter
    ) internal {
        IOptInService(addressbook.services.networkOptInService).optIn(networkAdapter.network);
    }

    // 3. Network to Vault Opt-in
    // Networks can opt into vaults to set maximum stake limits they’re willing to accept. This is done using the setMaxNetworkLimit function of the vault’s delegator.
    function _networkOptInToSymbioticVault(
        SymbioticNetworkAdapterConfig memory networkAdapter,
        SymbioticVaultConfig memory vault,
        address agent
    ) internal {
        SymbioticNetwork(networkAdapter.network).registerVault(vault.vault, agent);
    }

    // 4. Vault to Agent Delegation
    // > Vaults can opt into networks by setting non-zero limits.
    // > https://docs.symbiotic.fi/modules/registries/#vault-allocation-to-networks
    // Since CAP want agent isolation we have a subnetwork per agent
    // this means that setting the network limit is the same as setting the agent delegation
    function _symbioticVaultDelegateToAgent(
        SymbioticVaultConfig memory vault,
        SymbioticNetworkAdapterConfig memory networkAdapter,
        address agent,
        uint256 amount
    ) internal {
        // avoid AlreadySet() errors that happens when setting the same amount twice
        uint256 maxNetworkLimit = IOperatorNetworkSpecificDelegator(vault.delegator).maxNetworkLimit(
            SymbioticNetworkMiddleware(networkAdapter.networkMiddleware).subnetwork(agent)
        );
        if (maxNetworkLimit != amount) {
            SymbioticNetwork(networkAdapter.network).setDelegation(vault.vault, agent, amount);
        }
    }
}
