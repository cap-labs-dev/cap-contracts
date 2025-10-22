// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";
// import { Network } from "../../contracts/delegation/providers/symbiotic/Network.sol";
// import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
import { ImplementationsConfig, InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { EigenConfig, EigenImplementationsConfig } from "../../contracts/deploy/interfaces/EigenDeployConfig.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";
import { FeeReceiver } from "../../contracts/feeReceiver/FeeReceiver.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";
import { PriceOracle } from "../../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../../contracts/oracle/RateOracle.sol";
import { VaultAdapter } from "../../contracts/oracle/libraries/VaultAdapter.sol";
import { FractionalReserve } from "../../contracts/vault/FractionalReserve.sol";
import { Minter } from "../../contracts/vault/Minter.sol";
import { Vault } from "../../contracts/vault/Vault.sol";

import { EigenAdapterConfigSerializer } from "../config/EigenAdapterConfigSerializer.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { VaultConfigSerializer } from "../config/VaultConfigSerializer.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

struct NamedProxy {
    address proxy;
    address implementation;
    string name;
}

contract CheckProxyImplem is
    Script,
    InfraConfigSerializer,
    VaultConfigSerializer,
    SymbioticAdapterConfigSerializer,
    EigenAdapterConfigSerializer
{
    using Strings for address;

    ImplementationsConfig implems;
    InfraConfig infra;
    VaultConfig vaultConfig;
    SymbioticNetworkAdapterImplementationsConfig symbioticImplems;
    SymbioticNetworkAdapterConfig symbioticAdapter;
    EigenImplementationsConfig eigenImplems;
    EigenConfig eigenAdapter;
    AccessControl accessControl;

    NamedProxy[] namedProxies;

    function run() external {
        (implems,, infra) = _readInfraConfig();
        vaultConfig = _readVaultConfig("cUSD");
        accessControl = AccessControl(infra.accessControl);
        (symbioticImplems, symbioticAdapter) = _readSymbioticConfig();
        (eigenImplems, eigenAdapter) = _readEigenConfig();
        namedProxies = [
            NamedProxy({
                proxy: 0xCCccFf7F858dA3aDB1E2C7fbB5A5B32fA745CCCC,
                implementation: 0xce2177833E400F91bb308308f7d9933e48982b01,
                name: "Known poisoned proxy"
            }),
            NamedProxy({ proxy: infra.accessControl, implementation: implems.accessControl, name: "Access Control" }),
            NamedProxy({ proxy: infra.lender, implementation: implems.lender, name: "Lender" }),
            NamedProxy({ proxy: infra.delegation, implementation: implems.delegation, name: "Delegation" }),
            NamedProxy({ proxy: infra.oracle, implementation: implems.oracle, name: "Oracle" }),
            NamedProxy({
                proxy: infra.chainlinkPoRAddressList,
                implementation: implems.chainlinkPoRAddressList,
                name: "Chainlink PoR Address List"
            }),
            NamedProxy({
                proxy: symbioticAdapter.networkMiddleware,
                implementation: symbioticImplems.networkMiddleware,
                name: "Network Middleware"
            }),
            NamedProxy({ proxy: symbioticAdapter.network, implementation: symbioticImplems.network, name: "Network" }),
            NamedProxy({
                proxy: symbioticAdapter.agentManager,
                implementation: symbioticImplems.agentManager,
                name: "Agent Manager"
            }),
            NamedProxy({
                proxy: eigenAdapter.eigenServiceManager,
                implementation: eigenImplems.eigenServiceManager,
                name: "Service Manager"
            }),
            NamedProxy({ proxy: eigenAdapter.agentManager, implementation: eigenImplems.agentManager, name: "Agent Manager" })
        ];

        string[1] memory capTokenSymbols = ["cUSD"];
        for (uint256 i = 0; i < capTokenSymbols.length; i++) {
            string memory symbol = capTokenSymbols[i];
            _addVault(symbol);
        }

        vm.startBroadcast();
        for (uint256 i = 0; i < namedProxies.length; i++) {
            console.log("Checking Proxy implementation for", namedProxies[i].name, "Contract...");
            NamedProxy memory namedProxy = namedProxies[i];
            checkImplementation(namedProxy);
            console.log("");
        }
        vm.stopBroadcast();
    }

    function _addVault(string memory symbol) internal {
        vaultConfig = _readVaultConfig(symbol);

        namedProxies.push(
            NamedProxy({ proxy: vaultConfig.capToken, implementation: implems.capToken, name: "Cap Token" })
        );
        namedProxies.push(
            NamedProxy({ proxy: vaultConfig.stakedCapToken, implementation: implems.stakedCap, name: "Staked Cap Token" })
        );
        namedProxies.push(
            NamedProxy({ proxy: vaultConfig.feeAuction, implementation: implems.feeAuction, name: "Fee Auction" })
        );
        namedProxies.push(
            NamedProxy({ proxy: vaultConfig.feeReceiver, implementation: implems.feeReceiver, name: "Fee Receiver" })
        );

        for (uint256 i = 0; i < vaultConfig.debtTokens.length; i++) {
            address debtToken = vaultConfig.debtTokens[i];
            string memory debtTokenName = IERC20Metadata(debtToken).name();
            namedProxies.push(
                NamedProxy({
                    proxy: debtToken,
                    implementation: implems.debtToken,
                    name: string.concat("Debt Token ", Strings.toString(i), " of cUSD vault (", debtTokenName, ")")
                })
            );
        }
    }

    // @dev This is the same as the implementation slot in ERC1967Utils.sol
    bytes32 internal constant ERC1967_UTILS_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function checkImplementation(NamedProxy memory namedProxy) internal view {
        bytes32 implemSlotData = vm.load(address(namedProxy.proxy), ERC1967_UTILS_IMPLEMENTATION_SLOT);
        address implementation = address(uint160(uint256(implemSlotData)));
        address expectedImplementation = namedProxy.implementation;
        if (implementation != expectedImplementation) {
            console.log("Implementation mismatch for", namedProxy.name);
            console.log("Expected:", expectedImplementation);
            console.log("Actual:", implementation);
        } else {
            console.log("Implementation matches for", namedProxy.name);
        }
    }
}
