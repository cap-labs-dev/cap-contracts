// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { stdJson } from "forge-std/StdJson.sol";
import { Vm } from "forge-std/Vm.sol";

import {
    TestEigenParams,
    TestForkConfig,
    TestHarnessConfig,
    TestInfraParams,
    TestOracleParams,
    TestScenarioParams,
    TestSymbioticParams
} from "../interfaces/TestHarnessConfig.sol";

/// @dev Loads a `TestHarnessConfig` from JSON, with sane fallbacks.
/// This intentionally lives under `test/` because it uses Foundry cheatcodes + filesystem reads.
contract TestHarnessConfigReader {
    using stdJson for string;

    string internal constant DEFAULT_HARNESS_CONFIG_PATH = "config/test-harness.json";
    string internal constant HARNESS_CONFIG_ENV = "CAP_TEST_HARNESS_CONFIG";

    function _loadHarnessConfigOrDefault(uint256 chainId) internal view returns (TestHarnessConfig memory cfg) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        string memory path = vm.envOr(HARNESS_CONFIG_ENV, DEFAULT_HARNESS_CONFIG_PATH);
        if (!vm.exists(path)) return _defaultHarnessConfig();

        string memory json = vm.readFile(path);
        if (!_jsonContainsChainIdKey(json, vm.toString(chainId))) return _defaultHarnessConfig();
        string memory selectorPrefix = string.concat("$['", vm.toString(chainId), "']");

        // If the chain id key is missing, fall back to defaults.
        // stdJson will revert on missing keys; use `exists` on the whole file instead of per-key.
        // We keep this simple: if any required key is missing, tests should fail loudly.
        cfg.fork = TestForkConfig({
            useMockBackingNetwork: json.readBool(string.concat(selectorPrefix, ".fork.useMockBackingNetwork")),
            mockChainId: json.readUint(string.concat(selectorPrefix, ".fork.mockChainId")),
            rpcUrl: json.readString(string.concat(selectorPrefix, ".fork.rpcUrl")),
            blockNumber: json.readUint(string.concat(selectorPrefix, ".fork.blockNumber"))
        });

        cfg.infra = TestInfraParams({
            delegationEpochDuration: json.readUint(string.concat(selectorPrefix, ".infra.delegationEpochDuration"))
        });

        cfg.oracle = TestOracleParams({
            usdPrice8: json.readInt(string.concat(selectorPrefix, ".oracle.usdPrice8")),
            usdRateRay: json.readUint(string.concat(selectorPrefix, ".oracle.usdRateRay")),
            ethPrice8: json.readInt(string.concat(selectorPrefix, ".oracle.ethPrice8")),
            ethRateRay: json.readUint(string.concat(selectorPrefix, ".oracle.ethRateRay")),
            permissionedPrice8: json.readInt(string.concat(selectorPrefix, ".oracle.permissionedPrice8")),
            permissionedRateRay: json.readUint(string.concat(selectorPrefix, ".oracle.permissionedRateRay")),
            extraChainlinkAsset: json.readAddress(string.concat(selectorPrefix, ".oracle.extraChainlinkAsset"))
        });

        cfg.fee.minMintFee = json.readUint(string.concat(selectorPrefix, ".fee.minMintFee"));
        cfg.fee.slope0 = json.readUint(string.concat(selectorPrefix, ".fee.slope0"));
        cfg.fee.slope1 = json.readUint(string.concat(selectorPrefix, ".fee.slope1"));
        cfg.fee.mintKinkRatio = json.readUint(string.concat(selectorPrefix, ".fee.mintKinkRatio"));
        cfg.fee.burnKinkRatio = json.readUint(string.concat(selectorPrefix, ".fee.burnKinkRatio"));
        cfg.fee.optimalRatio = json.readUint(string.concat(selectorPrefix, ".fee.optimalRatio"));

        cfg.symbiotic = TestSymbioticParams({
            vaultEpochDuration: uint48(json.readUint(string.concat(selectorPrefix, ".symbiotic.vaultEpochDuration"))),
            feeAllowed: json.readUint(string.concat(selectorPrefix, ".symbiotic.feeAllowed")),
            defaultAgentLtvRay: json.readUint(string.concat(selectorPrefix, ".symbiotic.defaultAgentLtvRay")),
            defaultAgentLiquidationThresholdRay: json.readUint(
                string.concat(selectorPrefix, ".symbiotic.defaultAgentLiquidationThresholdRay")
            ),
            defaultDelegationRateRay: json.readUint(
                string.concat(selectorPrefix, ".symbiotic.defaultDelegationRateRay")
            ),
            defaultCoverageCapUsd8: json.readUint(string.concat(selectorPrefix, ".symbiotic.defaultCoverageCapUsd8")),
            mockAgentCoverageUsd8: json.readUint(string.concat(selectorPrefix, ".symbiotic.mockAgentCoverageUsd8"))
        });

        cfg.eigen = TestEigenParams({
            rewardDuration: uint32(json.readUint(string.concat(selectorPrefix, ".eigen.rewardDuration"))),
            delegationAmountNoDecimals: json.readUint(
                string.concat(selectorPrefix, ".eigen.delegationAmountNoDecimals")
            )
        });

        cfg.scenario = TestScenarioParams({
            postDeployTimeSkip: json.readUint(string.concat(selectorPrefix, ".scenario.postDeployTimeSkip"))
        });
    }

    function _jsonContainsChainIdKey(string memory json, string memory chainId) internal pure returns (bool) {
        bytes memory haystack = bytes(json);
        bytes memory needle = bytes(string.concat("\"", chainId, "\""));
        if (needle.length == 0 || haystack.length < needle.length) return false;

        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    function _defaultHarnessConfig() internal pure returns (TestHarnessConfig memory cfg) {
        cfg.fork = TestForkConfig({
            useMockBackingNetwork: false,
            mockChainId: 11155111,
            rpcUrl: "https://mainnet.gateway.tenderly.co",
            blockNumber: 23285216
        });

        cfg.infra = TestInfraParams({ delegationEpochDuration: 1 days });

        cfg.oracle = TestOracleParams({
            usdPrice8: 1e8,
            usdRateRay: uint256(0.1e27),
            ethPrice8: 2600e8,
            ethRateRay: uint256(0.1e27),
            permissionedPrice8: 1e8,
            permissionedRateRay: uint256(0.1e27),
            extraChainlinkAsset: 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704
        });

        cfg.fee.minMintFee = 0.005e27;
        cfg.fee.slope0 = 0;
        cfg.fee.slope1 = 0;
        cfg.fee.mintKinkRatio = 0.85e27;
        cfg.fee.burnKinkRatio = 0.15e27;
        cfg.fee.optimalRatio = 0.33e27;

        cfg.symbiotic = TestSymbioticParams({
            vaultEpochDuration: 7 days,
            feeAllowed: 1000,
            defaultAgentLtvRay: 0.5e27,
            defaultAgentLiquidationThresholdRay: 0.7e27,
            defaultDelegationRateRay: 0.02e27,
            defaultCoverageCapUsd8: 1_000_000_000_000e8,
            mockAgentCoverageUsd8: 1_000_000e8
        });

        cfg.eigen = TestEigenParams({ rewardDuration: 7, delegationAmountNoDecimals: 10 });

        cfg.scenario = TestScenarioParams({ postDeployTimeSkip: 28 days });
    }
}

