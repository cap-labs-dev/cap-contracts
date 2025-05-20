// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { LzAddressbook, LzUtils } from "../contracts/deploy/utils/LzUtils.sol";
import { WalletUtils } from "../contracts/deploy/utils/WalletUtils.sol";

import { LzMessageProxy } from "../contracts/testnetCampaign/LzMessageProxy.sol";
import { PreMainnetVault } from "../contracts/testnetCampaign/PreMainnetVault.sol";
import { L2Token } from "../contracts/token/L2Token.sol";

contract DeployPreMainnetVaultAndL2Token is Script, LzUtils, WalletUtils {
    using stdJson for string;

    // Chain IDs
    string constant SOURCE_RPC_URL = "ethereum-holesky";
    uint256 constant SOURCE_CHAIN_ID = 17000;

    string constant PROXY_RPC_URL = "ethereum-sepolia";
    uint256 constant PROXY_CHAIN_ID = 11155111;

    string constant TARGET_RPC_URL = "megaeth-testnet";
    uint256 constant TARGET_CHAIN_ID = 6342;

    // Max campaign length (1 week)
    uint48 constant MAX_CAMPAIGN_LENGTH = 7 days;

    uint256 sourceForkId;
    uint256 proxyForkId;
    uint256 targetForkId;

    // Deployment addresses
    address public usdc;
    address public cap;
    address public stakedCap;

    // Deployed contracts
    PreMainnetVault public vault;
    LzMessageProxy public proxy;
    L2Token public l2Token;

    // LayerZero configs
    LzAddressbook public sourceConfig;
    LzAddressbook public proxyConfig;
    LzAddressbook public targetConfig;

    function run() external {
        address deployer = getWalletAddress();
        sourceForkId = vm.createFork(SOURCE_RPC_URL);
        proxyForkId = vm.createFork(PROXY_RPC_URL);
        targetForkId = vm.createFork(TARGET_RPC_URL);

        // Get deployment configuration
        usdc = vm.envAddress("USDC_ADDRESS");
        cap = vm.envAddress("CAP_ADDRESS");
        stakedCap = vm.envAddress("STAKED_CAP_ADDRESS");

        // Get LayerZero configuration for both chains
        sourceConfig = _getLzAddressbook(SOURCE_CHAIN_ID);
        proxyConfig = _getLzAddressbook(PROXY_CHAIN_ID);
        targetConfig = _getLzAddressbook(TARGET_CHAIN_ID);

        // Deploy PreMainnetVault on Sepolia
        vm.selectFork(sourceForkId);
        vm.startBroadcast();
        vault = new PreMainnetVault(
            usdc, cap, stakedCap, address(sourceConfig.endpointV2), proxyConfig.eid, MAX_CAMPAIGN_LENGTH
        );
        console.log(string.concat("PreMainnetVault deployed on ", SOURCE_RPC_URL, " at:"), address(vault));
        vm.stopBroadcast();

        // Deploy L2Token on Arbitrum Sepolia
        vm.selectFork(proxyForkId);
        vm.startBroadcast();
        proxy = new LzMessageProxy(address(proxyConfig.endpointV2));
        console.log(string.concat("LzMessageProxy deployed on ", PROXY_RPC_URL, " at:"), address(proxy));
        vm.stopBroadcast();

        // Deploy L2Token on Arbitrum Sepolia
        vm.selectFork(targetForkId);
        vm.startBroadcast();
        l2Token = new L2Token("Boosted cUSD", "bcUSD", address(targetConfig.endpointV2), deployer);
        console.log(string.concat("L2Token deployed on ", TARGET_RPC_URL, " at:"), address(l2Token));
        vm.stopBroadcast();

        // Link the contracts
        bytes32 l2TokenPeer = addressToBytes32(address(l2Token));
        bytes32 proxyPeer = addressToBytes32(address(proxy));
        bytes32 vaultPeer = addressToBytes32(address(vault));

        // vault -> proxy -> l2Token

        // vault <-> proxy
        {
            vm.selectFork(sourceForkId);
            vm.startBroadcast();
            vault.setPeer(proxyConfig.eid, proxyPeer);
            console.log(string.concat("Set PreMainnetVault's peer to LzMessageProxy on ", SOURCE_RPC_URL));
            vm.stopBroadcast();

            vm.selectFork(proxyForkId);
            vm.startBroadcast();
            proxy.setPeer(sourceConfig.eid, vaultPeer);
            console.log(string.concat("Set Proxy's peer to PreMainnetVault on ", PROXY_RPC_URL));
            vm.stopBroadcast();
        }

        // proxy <-> l2Token
        {
            vm.selectFork(proxyForkId);
            vm.startBroadcast();
            proxy.setPeer(targetConfig.eid, l2TokenPeer);
            console.log(string.concat("Set LzMessageProxy's peer to L2Token on ", PROXY_RPC_URL));
            vm.stopBroadcast();

            vm.selectFork(targetForkId);
            vm.startBroadcast();
            l2Token.setPeer(proxyConfig.eid, proxyPeer);
            console.log(string.concat("Set L2Token's peer to LzMessageProxy on ", TARGET_RPC_URL));
            vm.stopBroadcast();
        }
    }
}
