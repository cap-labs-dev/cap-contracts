// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IStakedCap } from "../../contracts/interfaces/IStakedCap.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { VaultUpgradeable } from "../../contracts/vault/VaultUpgradeable.sol";

import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockDelegation } from "../mocks/MockDelegation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";

contract StakedCapStakeTest is Test, TestDeployer {
    address user;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);

        user = makeAddr("test_user");
        _initTestUserMintCapToken(env.vault, user, 4000e18);
    }

    function test_staked_cap_stake() public {
        vm.startPrank(user);

        uint256 cUSDStakedBefore = cUSD.balanceOf(address(scUSD));

        // Now stake the cUSD tokens
        cUSD.approve(address(scUSD), 100e18);
        scUSD.deposit(100e18, user);

        assertEq(scUSD.balanceOf(user), 100e18, "Should have staked cUSD tokens");
        assertEq(cUSD.balanceOf(address(scUSD)), cUSDStakedBefore + 100e18, "Vault should have received cUSD");
        assertEq(cUSD.balanceOf(user), 3900e18, "User must have transferred the cUSD");
    }
}
