// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { SymbioticVaultConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { console } from "forge-std/console.sol";

contract SymbioticSlashAssumptionsTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env, 100);

        // reset the initial stakes for this test
        {
            _timeTravel(symbioticWethVault.vaultEpochDuration + 1 days);
        }

        vm.startPrank(env.users.middleware_admin);

        SymbioticNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setFeeAllowed(0.09e18);
        vm.stopPrank();
    }

    function _get_stake_at(SymbioticVaultConfig memory _vault, address _agent, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        bytes32 subnetwork =
            SymbioticNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).subnetwork(_agent);
        return IBaseDelegator(_vault.delegator).stakeAt(subnetwork, _agent, uint48(_timestamp), "");
    }

    function test_can_slash_after_restaker_undelegation() public {
        SymbioticVaultConfig memory _vault = symbioticWethVault;
        SymbioticNetworkMiddleware _middleware =
            SymbioticNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);

        // we work from the perspective of the network
        address agent1 = env.testUsers.agents[0];
        address operator = SymbioticNetwork(env.symbiotic.networkAdapter.network).getOperator(agent1);
        uint256 restakersDepositedAmount = 100e18 * 3;
        assertEq(_get_stake_at(_vault, operator, block.timestamp), restakersDepositedAmount); // this is what the TestDeployer sets

        // now, the restaker completely undelegates from the usdt vault
        _timeTravel(1 days);

        _proportionallyWithdrawFromVault(env, _vault.vault, restakersDepositedAmount / 3, true);

        // the stake should immediately drop to 0
        assertEq(_get_stake_at(_vault, operator, block.timestamp), 0);

        _timeTravel(3);

        assertEq(_get_stake_at(_vault, operator, block.timestamp), 0);
        assertEq(_get_stake_at(_vault, operator, block.timestamp - 1), 0);
        assertEq(_get_stake_at(_vault, operator, block.timestamp - 2), 0);
        assertEq(_get_stake_at(_vault, operator, block.timestamp - 3), 0);
        assertEq(_get_stake_at(_vault, operator, block.timestamp - 4), restakersDepositedAmount);
        assertEq(_get_stake_at(_vault, operator, block.timestamp - 5), restakersDepositedAmount);

        /// ==== try slashing
        bytes32 agent1_subnetwork = _middleware.subnetwork(operator);
        vm.startPrank(address(_middleware));

        // we cannot request a slash for "right now", even though there is a stake to slash
        vm.expectRevert(ISlasher.InvalidCaptureTimestamp.selector);
        ISlasher(_vault.slasher).slash(agent1_subnetwork, operator, 10, uint48(block.timestamp), "");

        // we cannot request a slash for a timestamp where there is no stake
        vm.expectRevert(ISlasher.InsufficientSlash.selector);
        ISlasher(_vault.slasher).slash(agent1_subnetwork, operator, 10, uint48(block.timestamp - 1), "");

        // we can slash for a timestamp where there is a stake
        ISlasher(_vault.slasher).slash(agent1_subnetwork, operator, 10, uint48(block.timestamp - 4), "");
    }

    function test_setting_shares_but_reading_stake() public {
        SymbioticVaultConfig memory _vault = symbioticWethVault;

        // we work from the perspective of the network
        address agent1 = env.testUsers.agents[0];
        address operator = SymbioticNetwork(env.symbiotic.networkAdapter.network).getOperator(agent1);

        assertEq(_get_stake_at(_vault, operator, block.timestamp), 100e18 * 3); // this is what the TestDeployer sets

        _timeTravel(1);

        _proportionallyWithdrawFromVault(env, _vault.vault, 100e18, true);

        assertEq(_get_stake_at(_vault, operator, block.timestamp), 0);

        _timeTravel(1);

        _symbioticMintAndStakeInVault(_vault.vault, env.testUsers.restakers[0], 10e18);

        _timeTravel(1);

        assertEq(_get_stake_at(_vault, operator, block.timestamp), 10e18);
    }

    function test_slashing_decreases_the_operator_total_stake() public {
        SymbioticVaultConfig memory _vault = symbioticWethVault;
        SymbioticNetworkMiddleware _middleware =
            SymbioticNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);

        address agent1 = _getRandomAgent();
        address operator = SymbioticNetwork(env.symbiotic.networkAdapter.network).getOperator(agent1);
        bytes32 agent1_subnetwork = _middleware.subnetwork(operator);

        assertEq(_get_stake_at(_vault, operator, block.timestamp), 100e18 * 3);

        // slash 10% of the stake
        vm.startPrank(address(_middleware));
        ISlasher(_vault.slasher).slash(agent1_subnetwork, operator, 10e18, uint48(block.timestamp - 1), "");
        vm.stopPrank();

        _timeTravel(1);

        // the total stake should decrease by 10%
        assertEq(_get_stake_at(_vault, operator, block.timestamp), 100e18 * 2.9);
    }
}
