// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UsersConfig } from "../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { TestUsersConfig } from "../interfaces/TestDeployConfig.sol";
import { Test } from "forge-std/Test.sol";

contract DeployTestUsers is Test {
    function _deployTestUsers() internal returns (UsersConfig memory users, TestUsersConfig memory testUsers) {
        testUsers.agent = makeAddr("agent");
        testUsers.stablecoin_minter = makeAddr("stablecoin_minter");
        testUsers.liquidator = makeAddr("liquidator");
        vm.deal(testUsers.agent, 100 ether);
        vm.deal(testUsers.stablecoin_minter, 100 ether);
        vm.deal(testUsers.liquidator, 100 ether);

        users.deployer = makeAddr("deployer");
        users.access_control_admin = makeAddr("access_control_admin");
        users.address_provider_admin = makeAddr("address_provider_admin");
        users.interest_receiver = makeAddr("interest_receiver");
        users.vault_keeper = makeAddr("vault_keeper");
        users.oracle_admin = makeAddr("user_oracle_admin");
        users.rate_oracle_admin = makeAddr("user_rate_oracle_admin");
        users.vault_config_admin = makeAddr("user_vault_config_admin");
        users.lender_admin = makeAddr("user_lender_admin");
        users.delegation_admin = makeAddr("user_delegation_admin");
        vm.deal(users.deployer, 100 ether);
        vm.deal(users.access_control_admin, 100 ether);
        vm.deal(users.address_provider_admin, 100 ether);
        vm.deal(users.interest_receiver, 100 ether);
        vm.deal(users.vault_keeper, 100 ether);
        vm.deal(users.oracle_admin, 100 ether);
        vm.deal(users.rate_oracle_admin, 100 ether);
        vm.deal(users.lender_admin, 100 ether);
        vm.deal(users.vault_config_admin, 100 ether);
        vm.deal(users.delegation_admin, 100 ether);
    }
}
