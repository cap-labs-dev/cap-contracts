// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { BeaconFactory } from "../../cap/BeaconFactory.sol";
import { InterestRateModel } from "../../cap/InterestRateModel.sol";
import { Registry } from "../../cap/Registry.sol";
import { Stablecoin } from "../../cap/Stablecoin.sol";
import { Vault } from "../../cap/Vault.sol";
import { ChainlinkAdapter } from "../../cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../cap/oracle/Oracle.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { CapRoles } from "../../utils/CapRoles.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";
import { Vm } from "forge-std/Vm.sol";

contract DeployInfra is ProxyUtils {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Deploy the shared infrastructure and initialize it
    /// @param implementations The implementation addresses
    /// @param users The admin and token configuration
    /// @return infra The deployed infrastructure addresses
    function _deployInfra(ImplementationsConfig memory implementations, UsersConfig memory users)
        internal
        returns (InfraConfig memory infra)
    {
        infra = _deployInfra(implementations, users, 0);
    }

    /// @dev Deploy the shared infrastructure and initialize it
    /// @param implementations The implementation addresses
    /// @param users The admin and token configuration
    /// @return infra The deployed infrastructure addresses
    function _deployInfra(
        ImplementationsConfig memory implementations,
        UsersConfig memory users,
        uint256 /* delegationEpochDuration */
    )
        internal
        returns (InfraConfig memory infra)
    {
        require(users.stablecoinUnderlying != address(0), "stablecoinUnderlying required");

        infra.accessManager = address(new AccessManager(users.admin));

        infra.vault = _proxy(implementations.vault, abi.encodeCall(Vault.initialize, (infra.accessManager)));

        // Deployed here rather than passed in. Handing the registry a foreign address meant the
        // real oracle was never built or read by anything that runs, so its answer scale went
        // unchecked against the consumers that carry it into collateral value. The adapter is
        // stateless and holds no per-asset configuration, so one instance serves every feed; the
        // governor still has to point each asset at it with {Oracle-setSource} before that asset
        // can back a market, which {Registry} enforces by pricing it at launch
        infra.oracle = _proxy(implementations.oracle, abi.encodeCall(Oracle.initialize, (infra.accessManager)));
        bytes memory adapterCode = type(ChainlinkAdapter).creationCode;
        address adapter;
        assembly {
            adapter := create(0, add(adapterCode, 0x20), mload(adapterCode))
        }
        infra.chainlinkAdapter = adapter;

        uint256 n = VM.getNonce(address(this));
        address irmAddr = VM.computeCreateAddress(address(this), n);
        address stablecoinAddr = VM.computeCreateAddress(address(this), n + 1);

        infra.irm = _proxy(
            implementations.irm,
            abi.encodeCall(
                InterestRateModel.initialize, (infra.accessManager, stablecoinAddr, 1e27, 2e27, 1e27, 0.02e27, 1 hours)
            )
        );

        infra.stablecoin = _proxy(
            implementations.stablecoin,
            abi.encodeCall(
                Stablecoin.initialize,
                (infra.accessManager, users.stablecoinUnderlying, "Cap USD", "cUSD", "", irmAddr, users.reserveVault)
            )
        );

        require(infra.irm == irmAddr, "irm addr");
        require(infra.stablecoin == stablecoinAddr, "stablecoin addr");

        infra.factory =
            _proxy(address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (infra.accessManager)));
        infra.floatingMarketBeacon = address(new UpgradeableBeacon(implementations.floatingMarket, users.admin));
        infra.fixedMarketBeacon = address(new UpgradeableBeacon(implementations.fixedMarket, users.admin));
        infra.trancheBeacon = address(new UpgradeableBeacon(implementations.tranche, users.admin));
        infra.underwriterBeacon = address(new UpgradeableBeacon(implementations.underwriter, users.admin));

        // {Registry-initialize} wires every shared selector, which is an ADMIN call on the
        // manager. Grant that before the proxy is created so the initializer can do its job
        address registryAddr = VM.computeCreateAddress(address(this), VM.getNonce(address(this)));
        AccessManager(infra.accessManager).grantRole(CapRoles.ADMIN, registryAddr, 0);
        AccessManager(infra.accessManager).grantRole(CapRoles.REGISTRY, registryAddr, 0);

        infra.registry = _proxy(
            implementations.registry,
            abi.encodeCall(
                Registry.initialize,
                (
                    infra.accessManager,
                    IRegistry.InitParams({
                        stablecoin: infra.stablecoin,
                        vault: infra.vault,
                        oracle: infra.oracle,
                        irm: infra.irm,
                        factory: infra.factory,
                        floatingMarketBeacon: infra.floatingMarketBeacon,
                        fixedMarketBeacon: infra.fixedMarketBeacon,
                        trancheBeacon: infra.trancheBeacon,
                        underwriterBeacon: infra.underwriterBeacon,
                        lt: 0.8e27,
                        buffer: 0.1e27,
                        targetHealth: 1.25e27
                    })
                )
            )
        );

        require(infra.registry == registryAddr, "registry addr");
    }
}
