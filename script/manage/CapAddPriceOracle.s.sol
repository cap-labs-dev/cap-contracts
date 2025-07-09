// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { LibsConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureOracle } from "../../contracts/deploy/service/ConfigureOracle.sol";

import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";

import { Oracle } from "../../contracts/oracle/Oracle.sol";

import { AaveAdapter } from "../../contracts/oracle/libraries/AaveAdapter.sol";
import { ChainlinkAdapter } from "../../contracts/oracle/libraries/ChainlinkAdapter.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract CapAddPriceOracle is Script, InfraConfigSerializer, ConfigureOracle {
    InfraConfig infra;
    LibsConfig libs;

    function run() external {
        (, libs, infra) = _readInfraConfig();

        address asset = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); //vm.envAddress("ASSET");
        address priceFeed = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        address aaveDataProvider = address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2); //vm.envAddress("PRICE_FEED");
        uint256 staleness = 86600;

        bool rateUpdate = true;
        bool priceUpdate = false;

        vm.startBroadcast();

        if (rateUpdate) {
            IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
                adapter: address(0xf4DE2D82904D528E8F0fE9c374218aE6B0A86d7e),
                payload: abi.encodeWithSelector(AaveAdapter.rate.selector, aaveDataProvider, asset)
            });
            Oracle(infra.oracle).setMarketOracleData(asset, oracleData);
        }

        if (priceUpdate) {
            IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
                adapter: address(0xc850409DC3587039e87930008217B6622CC3B2E2),
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, priceFeed)
            });
            Oracle(infra.oracle).setPriceOracleData(asset, oracleData);
            Oracle(infra.oracle).setPriceBackupOracleData(asset, oracleData);
            Oracle(infra.oracle).setStaleness(asset, staleness);
        }

        //_initChainlinkPriceOracle(libs, infra, asset, priceFeed);

        vm.stopBroadcast();
    }
}
