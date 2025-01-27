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

contract VaultMintTest is Test, TestDeployer {
    address user;

    function setUp() public {
        _deployCapTestEnvironment();

        // unwrap some config to make the tests more readable
        vault = env.vault;
        usdt = MockERC20(vault.assets[0]);
        usdc = MockERC20(vault.assets[1]);
        usdx = MockERC20(vault.assets[2]);
        cUSD = CapToken(vault.capToken);
        scUSD = StakedCap(vault.stakedCapToken);

        user = makeAddr("test_user");
    }

    function test_vault_mint_on_empty_vault() public {
        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e6; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);

        // Assert the minting was successful
        assertGt(cUSD.balanceOf(user), 0, "Should have received cUSD tokens");
        assertEq(usdt.balanceOf(address(cUSD)), amountIn, "Vault should have received USDT");
        assertEq(usdt.balanceOf(user), 0, "User should have spent USDT");
    }

    function test_vault_mint_with_different_prices() public {
        vm.startPrank(user);

        // Set USDT price to 1.02 USD
        MockChainlinkPriceFeed(env.oracleMocks.chainlinkPriceFeeds[0]).setLatestAnswer(102e8);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 90e6;
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);

        // We should receive less cUSD since USDT is worth more
        assertGe(cUSD.balanceOf(user), amountIn * 98 / 100, "Should have received less cUSD due to higher USDT price");
        assertEq(usdt.balanceOf(address(cUSD)), amountIn, "Vault should have received USDT");
    }

    function test_mint_on_non_empty_vault() public {
        _initTestVaultLiquidity(vault);

        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e6; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);
    }
}
