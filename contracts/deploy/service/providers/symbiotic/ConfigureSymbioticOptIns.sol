// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticNetwork } from "../../../../delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkAdapterConfig, SymbioticVaultConfig } from "../../../interfaces/SymbioticsDeployConfigs.sol";
import { SymbioticAddressbook } from "../../../utils/SymbioticUtils.sol";

import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";

contract ConfigureSymbioticOptIns {
    /// @dev Opt-ins in Symbiotic.
    /// See docs: https://docs.symbiotic.fi/modules/registries#opt-ins-in-symbiotic
    ///
    /// These helpers do not enforce msg.sender. Callers are expected to `vm.startPrank(...)`
    /// (tests) or otherwise ensure the correct actor is performing the opt-in.
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
}
