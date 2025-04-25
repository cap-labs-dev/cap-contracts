// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { LibsConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureOracle } from "../../contracts/deploy/service/ConfigureOracle.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract CapAddPriceOracle is Script, InfraConfigSerializer, ConfigureOracle {
    InfraConfig infra;
    LibsConfig libs;

    function run() external {
        (, libs, infra) = _readInfraConfig();

        address asset = vm.envAddress("ASSET");
        address priceFeed = vm.envAddress("PRICE_FEED");

        vm.startBroadcast();

        _initChainlinkPriceOracle(libs, infra, asset, priceFeed);

        vm.stopBroadcast();
    }
}
