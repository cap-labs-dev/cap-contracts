// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { LibsConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureOracle } from "../../contracts/deploy/service/ConfigureOracle.sol";

import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";

import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { CapTokenAdapter } from "../../contracts/oracle/libraries/CapTokenAdapter.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract CapAddPriceOracle is Script, InfraConfigSerializer, ConfigureOracle {
    InfraConfig infra;
    LibsConfig libs;

    function run() external {
        (, libs, infra) = _readInfraConfig();

        address asset = address(0xF79e8E7Ba2dDb5d0a7D98B1F57fCb8A50436E9aA); //vm.envAddress("ASSET");
        // address priceFeed = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);//vm.envAddress("PRICE_FEED");

        vm.startBroadcast();

        IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
            adapter: address(0xF7e1B01404676CDb1F2B7faA46D915Aa118918ac),
            payload: abi.encodeWithSelector(CapTokenAdapter.price.selector, asset)
        });
        Oracle(infra.oracle).setPriceOracleData(asset, oracleData);
        Oracle(infra.oracle).setPriceBackupOracleData(asset, oracleData);

        //_initChainlinkPriceOracle(libs, infra, asset, priceFeed);

        vm.stopBroadcast();
    }
}
