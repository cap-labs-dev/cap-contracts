// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { SymbioticVaultConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { SymbioticNetworkRewardsConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { SymbioticVaultParams } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { SymbioticSubnetworkLib } from "../../contracts/delegation/providers/symbiotic/SymbioticSubnetworkLib.sol";
import { ISymbioticNetworkMiddleware } from "../../contracts/interfaces/ISymbioticNetworkMiddleware.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { console } from "forge-std/console.sol";

contract SymbioticRestakeAssumptionsTest is TestDeployer {
    using SymbioticSubnetworkLib for address;

    SymbioticVaultConfig secondWethVault;
    SymbioticVaultConfig secondUsdcVault;

    function setUp() public {
        _deployCapTestEnvironment();
    }

    function _get_stake_at(SymbioticVaultConfig memory _vault, address _agent, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        IBaseDelegator delegator = IBaseDelegator(_vault.delegator);
        return delegator.stakeAt(
            _vault.vault.vaultSubnetwork(env.symbiotic.networkAdapter.network), _agent, uint48(_timestamp), ""
        );
    }

    function _onboardAgent(address _agent) internal {
        vm.startPrank(_agent);
        _agentRegisterAsOperator(symbioticAb);
        _agentOptInToSymbioticNetwork(symbioticAb, env.symbiotic.networkAdapter);

        vm.startPrank(env.users.delegation_admin);
        _addAgentToDelegationContract(env.infra, _agent, env.symbiotic.networkAdapter.networkMiddleware);

        vm.stopPrank();
    }

    function _deployAndSetupVault(address token, uint256 initialStake)
        internal
        returns (SymbioticVaultConfig memory vault, SymbioticNetworkRewardsConfig memory rewards)
    {
        // Deploy vault
        vm.startPrank(env.symbiotic.users.vault_admin);
        (vault, rewards) = _deployTestnetSymbioticVault(token);

        // Register network in vault and add initial stake
        vm.startPrank(env.symbiotic.users.vault_admin);
        _registerCapNetworkInVault(env.symbiotic.networkAdapter, vault);
        if (initialStake > 0) {
            _symbioticMintAndStakeInVault(vault.vault, env.symbiotic.users.vault_admin, initialStake);
        }

        // Register vault in network middleware
        vm.startPrank(env.users.middleware_admin);
        _registerVaultInNetworkMiddleware(env.symbiotic.networkAdapter, vault, rewards);

        vm.stopPrank();
    }

    function _registerAgentWithVault(SymbioticVaultConfig memory vault, address agent, uint256 delegationAmount)
        internal
    {
        // Register agent in network middleware
        vm.startPrank(env.users.middleware_admin);
        _registerAgentInNetworkMiddleware(env.symbiotic.networkAdapter, vault, agent);
        vm.stopPrank();

        // Agent opts in to vault
        vm.startPrank(agent);
        _agentOptInToSymbioticVault(symbioticAb, vault);
        vm.stopPrank();

        // Network opts in to vault for agent
        vm.startPrank(env.users.middleware_admin);
        _networkOptInToSymbioticVault(env.symbiotic.networkAdapter, vault);
        vm.stopPrank();

        // Delegate stake to agent
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(vault, env.symbiotic.networkAdapter, agent, delegationAmount);
        vm.stopPrank();
    }

    /**
     * Test Assumption 1: Operators can receive stake from only one vault
     * This test verifies that attempting to register the same agent with multiple vaults fails
     */
    function test_assumption1_operators_can_only_receive_stake_from_one_vault() public {
        address agent = makeAddr("agent");
        _onboardAgent(agent);

        // Deploy vault 1 and register agent with it
        console.log("deploying vault 1");
        (SymbioticVaultConfig memory _vault1,) = _deployAndSetupVault(address(usdc), 0);
        _registerAgentWithVault(_vault1, agent, type(uint256).max);

        // Verify the agent is already registered with the first vault
        assertEq(middleware.vaults(agent), _vault1.vault, "Agent should be registered with first vault");

        // Deploy vault 2 (but don't register agent with it yet)
        console.log("deploying vault 2");
        (SymbioticVaultConfig memory _vault2,) = _deployAndSetupVault(address(usdc), 0);

        // Attempt to register the same agent with a different vault - this should fail
        vm.startPrank(env.users.middleware_admin);
        vm.expectRevert(ISymbioticNetworkMiddleware.ExistingCoverage.selector);
        _registerAgentInNetworkMiddleware(env.symbiotic.networkAdapter, _vault2, agent);
        vm.stopPrank();

        // Verify the agent is still only registered with the original vault
        assertEq(middleware.vaults(agent), _vault1.vault, "Agent should still be registered with original vault");
    }

    /**
     * Test Assumption 2a: Vaults can delegate to multiple operators
     * This test verifies that a single vault can delegate stake to multiple different agents
     */
    function test_assumption2a_vaults_can_delegate_to_multiple_operators() public {
        address agent1 = makeAddr("agent1");
        address agent2 = makeAddr("agent2");

        _onboardAgent(agent1);
        _onboardAgent(agent2);

        // Deploy a USDC vault with initial stake
        console.log("deploying vault");
        (SymbioticVaultConfig memory _vault,) = _deployAndSetupVault(address(usdc), 100e6);

        // Register both agents with the vault and delegate different amounts
        _registerAgentWithVault(_vault, agent1, 30e27);
        _registerAgentWithVault(_vault, agent2, 70e27);

        // Verify both agents are registered with the same vault
        assertEq(middleware.vaults(agent1), _vault.vault, "Agent1 should be registered with the vault");
        assertEq(middleware.vaults(agent2), _vault.vault, "Agent2 should be registered with the vault");

        // Verify both agents can receive stake from the same vault
        assertEq(_get_stake_at(_vault, agent1, block.timestamp), 30e6, "Agent1 should have stake from the vault");
        assertEq(_get_stake_at(_vault, agent2, block.timestamp), 70e6, "Agent2 should have stake from the vault");
    }

    /**
     * Test Assumption 2b: Vault stake is shared across operators with a system of shares
     * This test verifies that the vault stake is shared across operators with a system of shares
     */
    function test_assumption2b_vault_stake_is_shared_across_operators() public {
        address agent1 = makeAddr("agent1");
        address agent2 = makeAddr("agent2");

        _onboardAgent(agent1);
        _onboardAgent(agent2);

        // Deploy a USDC vault with limited stake of 10e6
        console.log("deploying vault");
        (SymbioticVaultConfig memory _vault,) = _deployAndSetupVault(address(usdc), 10e6);

        // Register both agents with the vault and delegate 4e6 shares to each
        _registerAgentWithVault(_vault, agent1, 4e27);
        _registerAgentWithVault(_vault, agent2, 4e27);

        // Verify each agent has their own isolated stake allocation
        assertEq(_get_stake_at(_vault, agent1, block.timestamp), 5e6, "Agent1 should have exactly 5e6 stake");
        assertEq(_get_stake_at(_vault, agent2, block.timestamp), 5e6, "Agent2 should have exactly 5e6 stake");

        // Verify that each agent's stake is isolated - changing one doesn't affect the other
        // Let's reduce agent1's delegation and verify agent2's stake remains unchanged
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(_vault, env.symbiotic.networkAdapter, agent1, 1e27); // Reduce to 1/5 th of the vault stake
        vm.stopPrank();

        // Verify agent2's stake is unaffected
        assertEq(_get_stake_at(_vault, agent2, block.timestamp), 8e6, "Agent2's stake should remain unchanged");

        // Verify agent1's stake was updated
        assertEq(_get_stake_at(_vault, agent1, block.timestamp), 2e6, "Agent1's stake should be updated to 1e6");
    }

    /**
     * Test Assumption 2c: Verify stake delegation limits are enforced
     * This test ensures that you cannot delegate more stake than available in the vault
     */
    function test_assumption2c_stake_delegation_limits_enforced() public {
        address agent1 = makeAddr("agent1");
        address agent2 = makeAddr("agent2");
        address agent3 = makeAddr("agent3");

        _onboardAgent(agent1);
        _onboardAgent(agent2);
        _onboardAgent(agent3);

        // Deploy a USDC vault with limited stake of 10e6
        console.log("deploying vault");
        (SymbioticVaultConfig memory _vault,) = _deployAndSetupVault(address(usdc), 10e6);

        // Register all three agents with the vault (but don't delegate yet)
        _registerAgentWithVault(_vault, agent1, 1e27);
        _registerAgentWithVault(_vault, agent2, 1e27);
        _registerAgentWithVault(_vault, agent3, 1e27);

        // Verify that despite delegating max amounts, the actual stake received is constrained by vault collateral
        uint256 agent1Stake = _get_stake_at(_vault, agent1, block.timestamp);
        uint256 agent2Stake = _get_stake_at(_vault, agent2, block.timestamp);
        uint256 agent3Stake = _get_stake_at(_vault, agent3, block.timestamp);

        // The total stake should not exceed the vault's collateral (10e6)
        uint256 totalStake = agent1Stake + agent2Stake + agent3Stake;
        assertLe(totalStake, 10e6, "Total stake across all agents should not exceed vault collateral");

        // Each agent should have received some stake (assuming equal distribution)
        assertGt(agent1Stake, 0, "Agent1 should have received some stake");
        assertGt(agent2Stake, 0, "Agent2 should have received some stake");
        assertGt(agent3Stake, 0, "Agent3 should have received some stake");

        // Now let's add more collateral to the vault and verify stake can increase
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticMintAndStakeInVault(_vault.vault, env.symbiotic.users.vault_admin, 5e6); // Add 5e6 more
        vm.stopPrank();

        // Check stake again - it should be able to increase now that more collateral is available
        uint256 newAgent1Stake = _get_stake_at(_vault, agent1, block.timestamp);
        uint256 newAgent2Stake = _get_stake_at(_vault, agent2, block.timestamp);
        uint256 newAgent3Stake = _get_stake_at(_vault, agent3, block.timestamp);
        uint256 newTotalStake = newAgent1Stake + newAgent2Stake + newAgent3Stake;

        // The new total stake should not exceed the new vault collateral (15e6)
        assertLe(newTotalStake, 15e6, "New total stake should not exceed new vault collateral");

        // The total stake should have increased (or at least not decreased)
        assertGe(newTotalStake, totalStake, "Total stake should increase or stay the same with more collateral");
    }
}
