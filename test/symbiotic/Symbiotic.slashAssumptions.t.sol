// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
import { SymbioticVaultConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";

import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { console } from "forge-std/console.sol";

contract SymbioticSlashAssumptionsTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env);
    }

    function _get_stake_at(SymbioticVaultConfig memory _vault, address _agent, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        IBaseDelegator delegator = IBaseDelegator(_vault.delegator);
        NetworkMiddleware networkMiddleware = NetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);
        return delegator.stakeAt(networkMiddleware.subnetwork(), _agent, uint48(_timestamp), "");
    }

    function _set_delegation_amount(SymbioticVaultConfig memory _vault, address _agent, uint256 _amount) internal {
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultOptInToAgent(_vault, env.symbiotic.networkAdapter, _agent, _amount);
        vm.stopPrank();
    }

    function _request_slash(SymbioticVaultConfig memory _vault, address _agent, uint256 _amount, uint256 _timestamp)
        internal
    {
        NetworkMiddleware networkMiddleware = NetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);
        vm.startPrank(env.symbiotic.networkAdapter.networkMiddleware);
        ISlasher(_vault.slasher).slash(networkMiddleware.subnetwork(), _agent, _amount, uint48(_timestamp), "");
        vm.stopPrank();
    }

    function test_can_slash_after_restaker_undelegation() public {
        // we work from the perspective of the network
        address agent = env.testUsers.agents[0];

        uint256 stakeBefore = _get_stake_at(symbioticUsdtVault, agent, block.timestamp);
        assertEq(stakeBefore, 30000000000); // this is what the TestDeployer sets

        // now, the restaker completely undelegates from the usdt vault
        _set_delegation_amount(symbioticUsdtVault, agent, 0);

        // the stake should immediately drop to 0
        assertEq(_get_stake_at(symbioticUsdtVault, agent, block.timestamp), 0);
        // we should still be able to see data "in the past"
        assertEq(_get_stake_at(symbioticUsdtVault, agent, block.timestamp - 1), 30000000000);

        // since we don't like what we see, we can request a slash "in the past"
        _request_slash(symbioticUsdtVault, agent, 1000, block.timestamp - 1);
    }
}
