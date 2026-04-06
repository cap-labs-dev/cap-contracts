// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { FeeConfig } from "../../../contracts/deploy/interfaces/DeployConfigs.sol";

/// @dev High-level inputs that control how the test environment is deployed.
/// This is intentionally separate from `TestEnvConfig` (which is the *output* snapshot).
struct TestHarnessConfig {
    TestForkConfig fork;
    TestInfraParams infra;
    TestOracleParams oracle;
    FeeConfig fee;
    TestSymbioticParams symbiotic;
    TestEigenParams eigen;
    TestScenarioParams scenario;
}

struct TestForkConfig {
    /// @dev If true, do not fork and instead run against a lightweight mock backing network.
    bool useMockBackingNetwork;
    /// @dev Chain id to set when using the mock backing network.
    uint256 mockChainId;
    /// @dev RPC URL to fork from when not using the mock backing network.
    string rpcUrl;
    /// @dev Block number to fork at (0 means latest).
    uint256 blockNumber;
}

struct TestInfraParams {
    /// @dev Delegation epoch duration used when deploying infra.
    uint256 delegationEpochDuration;
}

struct TestOracleParams {
    /// @dev Default mock Chainlink price (8 decimals) used for USD-like assets.
    int256 usdPrice8;
    /// @dev Default annualized rate (ray) used for USD-like assets.
    uint256 usdRateRay;
    /// @dev Default mock Chainlink price (8 decimals) used for ETH-like assets.
    int256 ethPrice8;
    /// @dev Default annualized rate (ray) used for ETH-like assets.
    uint256 ethRateRay;
    /// @dev Default mock Chainlink price (8 decimals) used for permissioned assets.
    int256 permissionedPrice8;
    /// @dev Default annualized rate (ray) used for permissioned assets.
    uint256 permissionedRateRay;
    /// @dev Optional extra asset to configure a Chainlink price oracle for (0 disables).
    address extraChainlinkAsset;
}

struct TestSymbioticParams {
    uint48 vaultEpochDuration;
    uint256 feeAllowed;
    /// @dev Default agent parameters for tests (ray decimals).
    uint256 defaultAgentLtvRay;
    uint256 defaultAgentLiquidationThresholdRay;
    uint256 defaultDelegationRateRay;
    /// @dev Default coverage cap applied to all test agents.
    uint256 defaultCoverageCapUsd8;
    /// @dev Mock coverage value applied when using mock backing network.
    uint256 mockAgentCoverageUsd8;
}

struct TestEigenParams {
    uint32 rewardDuration;
    uint256 delegationAmountNoDecimals;
}

struct TestScenarioParams {
    /// @dev How far to fast-forward time at the end of deployment.
    uint256 postDeployTimeSkip;
}

