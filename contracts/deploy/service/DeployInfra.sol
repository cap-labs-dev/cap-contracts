// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { BeaconFactory } from "../../cap/BeaconFactory.sol";
import { InterestRateModel } from "../../cap/InterestRateModel.sol";
import { Registry } from "../../cap/Registry.sol";
import { Stablecoin } from "../../cap/Stablecoin.sol";
import { Vault } from "../../cap/Vault.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";
import { Vm } from "forge-std/Vm.sol";

contract DeployInfra is ProxyUtils {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _deployInfra(ImplementationsConfig memory implementations, UsersConfig memory users)
        internal
        returns (InfraConfig memory infra)
    {
        infra = _deployInfra(implementations, users, 0);
    }

    function _deployInfra(
        ImplementationsConfig memory implementations,
        UsersConfig memory users,
        uint256 /* delegationEpochDuration */
    )
        internal
        returns (InfraConfig memory infra)
    {
        require(users.stablecoinUnderlying != address(0), "stablecoinUnderlying required");
        require(users.stakedStablecoin != address(0), "stakedStablecoin required");
        require(users.oracle != address(0), "oracle required");

        infra.accessManager = address(new AccessManager(users.admin));

        infra.vault = _proxy(implementations.vault, abi.encodeCall(Vault.initialize, (infra.accessManager)));

        uint256 n = VM.getNonce(address(this));
        address irmAddr = VM.computeCreateAddress(address(this), n);
        address stablecoinAddr = VM.computeCreateAddress(address(this), n + 1);

        infra.irm = _proxy(
            implementations.irm,
            abi.encodeCall(
                InterestRateModel.initialize, (infra.accessManager, stablecoinAddr, 1e27, 2e27, 1e27, 0.02e27)
            )
        );

        infra.stablecoin = _proxy(
            implementations.stablecoin,
            abi.encodeCall(
                Stablecoin.initialize, (infra.accessManager, users.stablecoinUnderlying, "Cap USD", "cUSD", "", irmAddr)
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

        infra.registry = _proxy(
            implementations.registry,
            abi.encodeCall(
                Registry.initialize,
                (
                    infra.accessManager,
                    IRegistry.InitParams({
                        stablecoin: infra.stablecoin,
                        stakedStablecoin: users.stakedStablecoin,
                        vault: infra.vault,
                        oracle: users.oracle,
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
    }
}
