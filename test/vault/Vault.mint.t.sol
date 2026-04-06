// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IMinter } from "../../contracts/interfaces/IMinter.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { console } from "forge-std/console.sol";

contract VaultMintTest is TestDeployer {
    address user;

    function setUp() public {
        _deployCapTestEnvironment();

        user = makeAddr("test_user");
    }

    function test_vault_mint_on_empty_vault() public {
        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);

        // Assert the minting was successful
        assertGt(cUSD.balanceOf(user), 0, "Should have received cUSD tokens");
        assertEq(usdt.balanceOf(address(cUSD)), amountIn, "Vault should have received USDT");
        assertEq(usdt.balanceOf(user), 0, "User should have spent USDT");
    }

    function test_vault_mint_with_different_prices() public {
        // Set USDT price to 1.02 USD
        _setAssetOraclePrice(address(usdt), 102e8);

        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 90e18;
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);

        // Decimal 1:1 mint: 100e6 -> 100e18 before fees; min mint fee shaves ~0.5%
        assertApproxEqAbs(cUSD.balanceOf(user), 99.5e18, 1e15);
        assertEq(usdt.balanceOf(address(cUSD)), amountIn, "Vault should have received USDT");
    }

    function test_mint_reverts_when_oracle_deviation_exceeded() public {
        _initTestVaultLiquidity(usdVault);

        vm.startPrank(env.users.lender_admin);
        cUSD.setMaxMintSkewBps(50); // 0.5%
        vm.stopPrank();

        _setAssetOraclePrice(address(usdt), 200e8); // 2x vs $1 cap components → large oracleFair vs 1:1

        vm.startPrank(user);
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        vm.expectRevert(IMinter.MintOracleDeviation.selector);
        cUSD.mint(address(usdt), 100e6, 0, user, block.timestamp + 1 hours);
    }

    function test_mint_on_non_empty_vault() public {
        _initTestVaultLiquidity(usdVault);

        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);
    }

    function test_mint_with_invalid_asset() public {
        vm.startPrank(user);

        MockERC20 invalidAsset = new MockERC20("Invalid", "INV", 18);
        // Approve USDT spending
        invalidAsset.mint(user, 100e6);
        invalidAsset.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert();
        cUSD.mint(address(invalidAsset), amountIn, minAmountOut, user, deadline);
    }

    function test_mint_with_invalid_min_amount() public {
        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 105e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert();
        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);
    }

    function test_mint_with_invalid_deadline() public {
        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 100e6;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp - 1 hours;

        vm.expectRevert();
        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);
    }

    function test_mint_with_one_wei() public {
        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);

        // Mint cUSD with USDT
        uint256 amountIn = 1;
        uint256 minAmountOut = 0.995e12; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        cUSD.mint(address(usdt), amountIn, minAmountOut, user, deadline);
        // We have .5% less because of fees
        assertEq(cUSD.balanceOf(user), 0.995e12);
    }

    function test_mint_with_deposit_cap() public {
        vm.startPrank(env.users.vault_config_admin);
        cUSD.setDepositCap(address(usdt), 10e6);

        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 200e6);
        usdt.approve(address(cUSD), 200e6);

        // Mint cUSD with USDT over the deposit cap
        uint256 amountIn = 100e6;
        cUSD.mint(address(usdt), amountIn, 0, user, block.timestamp + 1 hours);
        uint256 userBalance = cUSD.balanceOf(user);
        // Only up to the cap is minted
        assertEq(userBalance, 9.95e18);
        console.log("totalSupply", cUSD.totalSupplies(address(usdt)));

        /// Should revert as amountOut is 0 and we revert on 0.
        vm.expectRevert();
        cUSD.mint(address(usdt), 90e6, 0, user, block.timestamp + 1 hours);

        vm.startPrank(env.users.vault_config_admin);
        cUSD.setDepositCap(address(usdt), 0);

        vm.startPrank(user);

        // Should revert because the deposit cap is 0
        vm.expectRevert();
        cUSD.mint(address(usdt), 10e6, 0, user, block.timestamp + 1 hours);

        vm.startPrank(env.users.vault_config_admin);
        cUSD.setDepositCap(address(usdt), type(uint256).max);

        vm.startPrank(user);
        // Should mint the full amount because the deposit cap is max
        cUSD.mint(address(usdt), 90e6, 0, user, block.timestamp + 1 hours);

        vm.startPrank(env.users.vault_config_admin);
        cUSD.setDepositCap(address(usdt), 110e6);
        console.log("totalSupply", cUSD.totalSupplies(address(usdt)));
        (uint256 amountOut,) = cUSD.getMintAmount(address(usdt), 90e6);
        assertEq(amountOut, 9.95e18);
    }
}
