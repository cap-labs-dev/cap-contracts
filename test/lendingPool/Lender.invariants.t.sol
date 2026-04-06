// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";
import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { TestHarnessConfig } from "../deploy/interfaces/TestHarnessConfig.sol";
import { InitTestVaultLiquidity } from "../deploy/service/InitTestVaultLiquidity.sol";

import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { RandomActorUtils } from "../deploy/utils/RandomActorUtils.sol";
import { RandomAssetUtils } from "../deploy/utils/RandomAssetUtils.sol";
import { TimeUtils } from "../deploy/utils/TimeUtils.sol";

import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { StdUtils } from "forge-std/StdUtils.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

contract LenderInvariantsTest is TestDeployer {
    TestLenderHandler public handler;
    address[] private actors;

    // Constants - all values in ray (1e27)
    uint256 private constant TARGET_HEALTH = 2e27; // 2.0 target health factor
    uint256 private constant BONUS_CAP = 1.1e27; // 110% bonus cap
    uint256 private constant GRACE_PERIOD = 1 days;
    uint256 private constant EXPIRY_PERIOD = 7 days;
    uint256 private constant EMERGENCY_LIQUIDATION_THRESHOLD = 0.91e27; // CR <110% have no grace periods

    function _harnessConfig() internal view override returns (TestHarnessConfig memory cfg) {
        cfg = super._harnessConfig();
        // Invariant suites must be hermetic and should never hit an RPC provider.
        cfg.fork.useMockBackingNetwork = true;
        // Use a chain id that exists in our addressbooks/config JSON.
        cfg.fork.mockChainId = 11155111;
        cfg.fork.blockNumber = 0;
        cfg.fork.rpcUrl = "";
    }

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);

        // Create and target handler
        handler = new TestLenderHandler(env);
        targetContract(address(handler));

        vm.label(address(handler), "TestLenderHandler");
    }

    /// @dev Debt for each agent's individual asset must never exceed that asset's debt-token supply.
    ///      Coverage decreases after borrowing can cause totalDebt > coverage (covered by liquidation);
    ///      this invariant focuses on the internal accounting consistency of the debt-token registry.
    /// forge-config: default.invariant.depth = 100
    function invariant_agentDelegationLimitsDebt() public view {
        address[] memory agents = env.testUsers.agents;
        address[] memory assets = env.usdVault.assets;

        for (uint256 j = 0; j < assets.length; j++) {
            address asset = assets[j];
            (,, address debtToken,,,,) = lender.reservesData(asset);
            if (debtToken == address(0)) continue;

            uint256 totalSupply = IERC20(debtToken).totalSupply();
            uint256 sumAgentBalance;
            for (uint256 i = 0; i < agents.length; i++) {
                uint256 agentBalance = IERC20(debtToken).balanceOf(agents[i]);
                sumAgentBalance += agentBalance;
                assertLe(agentBalance, totalSupply, "Agent debt token balance must not exceed total supply");
            }
            assertLe(sumAgentBalance, totalSupply, "Sum of agent debt balances must not exceed total debt token supply");
        }
    }

    /// @dev For each asset, the total debt token supply must equal the sum of all agent balances.
    ///      In this test suite only testUsers.agents borrow, so no other holders should exist.
    /// forge-config: default.invariant.depth = 100
    function invariant_debtTokenSupplyEqualsAgentBalances() public view {
        address[] memory agents = env.testUsers.agents;
        address[] memory assets = env.usdVault.assets;

        for (uint256 j = 0; j < assets.length; j++) {
            address asset = assets[j];
            (,, address debtToken,,,,) = lender.reservesData(asset);
            if (debtToken == address(0)) continue;

            uint256 totalSupply = IERC20(debtToken).totalSupply();
            uint256 sumAgentBalance;
            for (uint256 i = 0; i < agents.length; i++) {
                sumAgentBalance += IERC20(debtToken).balanceOf(agents[i]);
            }
            assertEq(totalSupply, sumAgentBalance, "Debt token total supply must equal sum of agent balances");
        }
    }

    /// @dev Any agent whose maxLiquidatable > 0 for any asset must have health < 1e27.
    /// forge-config: default.invariant.depth = 100
    function invariant_healthFactorConsistency() public view {
        address[] memory agents = env.testUsers.agents;
        address[] memory assets = env.usdVault.assets;

        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            // lender.agent() calls Delegation.coverage() which calls the network middleware.
            // Agents not registered via addAgent() have network == address(0), causing a revert.
            // Pre-check via lender.debt() (pure storage read) to skip unregistered agents.
            bool hasDebt = false;
            for (uint256 k = 0; k < assets.length; k++) {
                if (lender.debt(agent, assets[k]) > 0) {
                    hasDebt = true;
                    break;
                }
            }
            if (!hasDebt) continue;

            (, uint256 totalSlashableCollateral,,,,) = lender.agent(agent);
            if (totalSlashableCollateral == 0) continue;

            for (uint256 j = 0; j < assets.length; j++) {
                uint256 maxLiquidatable = lender.maxLiquidatable(agent, assets[j]);
                if (maxLiquidatable > 0) {
                    (,,,,, uint256 health) = lender.agent(agent);
                    assertLt(health, 1e27, "Liquidatable agents must have health < 1");
                    break;
                }
            }
        }
    }

    /// @dev Any agent with health >= 1e27 must have maxLiquidatable == 0 for every asset.
    ///      This is the inverse of invariant_healthFactorConsistency.
    /// forge-config: default.invariant.depth = 100
    function invariant_healthyAgentsNotLiquidatable() public view {
        address[] memory agents = env.testUsers.agents;
        address[] memory assets = env.usdVault.assets;

        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            // Skip unregistered agents — lender.agent() reverts for address(0) network entries.
            // lender.debt() is a safe pure storage read that works for any address.
            bool hasDebt = false;
            for (uint256 k = 0; k < assets.length; k++) {
                if (lender.debt(agent, assets[k]) > 0) {
                    hasDebt = true;
                    break;
                }
            }
            if (!hasDebt) continue;

            (,, uint256 totalDebt,,, uint256 health) = lender.agent(agent);
            if (totalDebt == 0) continue;
            if (health < 1e27) continue;

            for (uint256 j = 0; j < assets.length; j++) {
                assertEq(lender.maxLiquidatable(agent, assets[j]), 0, "Healthy agents must not be liquidatable");
            }
        }
    }
}

/**
 * @notice Handler contract for testing Lender invariants
 */
contract TestLenderHandler is StdUtils, TimeUtils, InitTestVaultLiquidity, RandomActorUtils, RandomAssetUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    TestEnvConfig env;

    Lender lender;

    constructor(TestEnvConfig memory _env)
        RandomActorUtils(_env.testUsers.agents)
        RandomAssetUtils(_env.usdVault.assets)
    {
        env = _env;
        lender = Lender(env.infra.lender);
    }

    function _randomUnpausedAsset(uint256 assetSeed) internal view returns (address) {
        address[] memory assets = allAssets();
        address[] memory unpausedAssets = new address[](assets.length);
        uint256 unpausedAssetCount = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            (,,,,, bool paused,) = lender.reservesData(assets[i]);
            if (!paused) {
                unpausedAssets[unpausedAssetCount++] = assets[i];
            }
        }

        if (unpausedAssetCount == 0) return address(0);

        return unpausedAssets[bound(assetSeed, 0, unpausedAssetCount - 1)];
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(actorSeed);
        address currentAsset = _randomUnpausedAsset(assetSeed);
        if (currentAsset == address(0)) return;

        uint256 availableToBorrow = lender.maxBorrowable(agent, currentAsset);
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);
        if (availableToBorrow < minBorrow) return;
        uint256 amount = bound(amountSeed, minBorrow, availableToBorrow);
        if (amount == 0) return;

        vm.startPrank(agent);
        lender.borrow(currentAsset, amount, agent);
        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(actorSeed);
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to actual borrowed amount
        uint256 debt = lender.debt(agent, currentAsset);
        uint256 amount = bound(amountSeed, 0, debt);

        // If the debt is less than the minimum borrow, the full debt must be repaid
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);

        (,, address debtToken,,,,) = lender.reservesData(currentAsset);
        uint256 index = DebtToken(debtToken).index();
        if ((index / 1e27) > amount) return;
        if (debt - amount <= minBorrow) amount = debt;
        if (amount == 0) return;

        // Mint tokens to repay
        MockERC20(currentAsset).mint(agent, amount);

        // Execute repay
        {
            vm.startPrank(agent);
            IERC20(currentAsset).approve(address(lender), amount);

            lender.repay(currentAsset, amount, agent);
            vm.stopPrank();
        }
    }

    function liquidate(uint256 agentSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(agentSeed);
        address currentAsset = randomAsset(assetSeed);
        address liquidator = makeAddr("liquidator");
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);

        uint256 amount = bound(amountSeed, 0, lender.maxLiquidatable(agent, currentAsset));
        if (amount < minBorrow) return;

        // Execute liquidation
        {
            vm.startPrank(liquidator);

            // Mint tokens to repay for the user liquidation
            MockERC20(currentAsset).mint(liquidator, amount);

            // Execute liquidation
            IERC20(currentAsset).approve(address(lender), amount);

            uint256 liquidationStart = lender.liquidationStart(agent);
            uint256 canLiquidateFrom = liquidationStart + lender.grace();
            uint256 canLiquidateUntil = canLiquidateFrom + lender.expiry();
            if (liquidationStart == 0) {
                lender.openLiquidation(agent);
                _timeTravel(lender.grace() + 1);
            } else if (block.timestamp <= canLiquidateFrom) {
                _timeTravel(canLiquidateFrom - block.timestamp);
            } else if (block.timestamp >= canLiquidateUntil) {
                // lender.closeLiquidation(agent);
                //  _timeTravel(1);
                lender.openLiquidation(agent);
                _timeTravel(lender.grace() + 1);
            }

            lender.liquidate(agent, currentAsset, amount, 0);
            vm.stopPrank();
        }
    }

    function setAgentCoverage(uint256 agentSeed, uint256 coverageSeed) external {
        uint256 coverage = bound(coverageSeed, 0, 1e50);
        address agent = randomActor(agentSeed);

        vm.prank(address(env.users.middleware_admin));
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockCoverage(agent, coverage);
        vm.stopPrank();
    }

    function setAgentSlashableCollateral(uint256 agentSeed, uint256 coverageSeed) external {
        uint256 coverage = bound(coverageSeed, 1, 1e50);
        address agent = randomActor(agentSeed);

        // get total debt of agent
        (,, uint256 totalDebt,,,) = lender.agent(agent);
        if (coverage < totalDebt) coverage = totalDebt;

        vm.prank(address(env.users.middleware_admin));
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware)
            .setMockSlashableCollateral(agent, coverage);
        vm.stopPrank();
    }

    function realizeInterest(uint256 assetSeed) external {
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to a reasonable range (using type(uint96).max to avoid overflow)
        uint256 maxRealization = lender.maxRealization(currentAsset);
        if (maxRealization == 0) return;

        lender.realizeInterest(currentAsset);
    }

    function wrapTime(uint256 timeSeed, uint256 blockNumberSeed) external {
        uint256 timestamp = bound(timeSeed, block.timestamp, block.timestamp + 100 days);
        uint256 blockNumber = bound(blockNumberSeed, block.number, block.number + 1000000);
        vm.warp(timestamp);
        vm.roll(blockNumber);
    }

    function realizeRestakerInterest(uint256 agentSeed, uint256 assetSeed) external {
        address agent = randomActor(agentSeed);
        address currentAsset = randomAsset(assetSeed);

        (uint256 maxRealizedInterest,) = lender.maxRestakerRealization(agent, currentAsset);
        if (maxRealizedInterest == 0) return;

        lender.realizeRestakerInterest(agent, currentAsset);
    }

    function closeLiquidation(uint256 agentSeed) external {
        address agent = randomActor(agentSeed);

        // Only attempt to close if there's an active liquidation
        if (lender.liquidationStart(agent) > 0) {
            (,,,,, uint256 health) = lender.agent(agent);
            // Only close if health is above 1e27 (healthy)
            if (health >= 1e27) {
                vm.prank(address(env.users.lender_admin));
                lender.closeLiquidation(agent);
                vm.stopPrank();
            }
        }
    }

    function pauseAsset(uint256 assetSeed, uint256 pauseFlagSeed) external {
        address currentAsset = randomAsset(assetSeed);
        bool shouldPause = bound(pauseFlagSeed, 0, 1) == 1; // Convert to boolean randomly

        // Only admin can pause/unpause
        vm.prank(address(env.users.lender_admin));
        lender.pauseAsset(currentAsset, shouldPause);
        vm.stopPrank();
    }

    // @dev Donate tokens to the lender's vault
    function donateAsset(uint256 assetSeed, uint256 amountSeed, uint256 targetSeed) external {
        address currentAsset = randomAsset(assetSeed);
        if (currentAsset == address(0)) return;

        address target = randomActor(targetSeed, address(env.usdVault.capToken), address(lender));

        uint256 amount = bound(amountSeed, 1, 1e50);
        MockERC20(currentAsset).mint(target, amount);
    }

    function donateGasToken(uint256 amountSeed, uint256 targetSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e50);
        address target = randomActor(targetSeed, address(env.usdVault.capToken), address(lender));

        vm.deal(
            target,
            amount /* we need gas to send gas */
        );
    }

    function setAssetOraclePrice(uint256 assetSeed, uint256 priceSeed) external {
        address currentAsset = randomAsset(assetSeed);
        int256 price = int256(bound(priceSeed, 0.001e8, 10_000e8));

        for (uint256 i = 0; i < env.usdOracleMocks.assets.length; i++) {
            if (env.usdOracleMocks.assets[i] == currentAsset) {
                MockChainlinkPriceFeed(env.usdOracleMocks.chainlinkPriceFeeds[i]).setLatestAnswer(price);
            }
        }
    }

    function setAssetOracleRate(uint256 assetSeed, uint256 rateSeed) external {
        address currentAsset = randomAsset(assetSeed);
        uint256 rate = bound(rateSeed, 0, 2e27);

        for (uint256 i = 0; i < env.usdOracleMocks.assets.length; i++) {
            if (env.usdOracleMocks.assets[i] == currentAsset) {
                MockAaveDataProvider(env.usdOracleMocks.aaveDataProviders[i]).setVariableBorrowRate(rate);
            }
        }
    }
}
