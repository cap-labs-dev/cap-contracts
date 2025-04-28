// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SymbioticNetworkAdapterConfig,
    SymbioticVaultConfig
} from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { ConfigureSymbioticOptIns } from
    "../../contracts/deploy/service/providers/symbiotic/ConfigureSymbioticOptIns.sol";

import { WalletUtils } from "../../contracts/deploy/utils/WalletUtils.sol";
import { InitSymbioticVaultLiquidity } from
    "../../test/deploy/service/provider/symbiotic/InitSymbioticVaultLiquidity.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { SymbioticVaultConfigSerializer } from "../config/SymbioticVaultConfigSerializer.sol";
import { Script } from "forge-std/Script.sol";

contract SymbioticStake is
    Script,
    WalletUtils,
    ConfigureSymbioticOptIns,
    SymbioticAdapterConfigSerializer,
    SymbioticVaultConfigSerializer,
    InitSymbioticVaultLiquidity
{
    SymbioticNetworkAdapterConfig networkAdapter;
    SymbioticVaultConfig vault;

    function run() external {
        (, networkAdapter) = _readSymbioticConfig();
        address restaker = getWalletAddress();

        (vault,) = _readSymbioticVaultConfig(vm.envAddress("VAULT"));
        uint256 amount = vm.envUint("AMOUNT");

        vm.startBroadcast();

        _symbioticMintAndStakeInVault(vault.vault, restaker, amount);

        vm.stopBroadcast();
    }
}
