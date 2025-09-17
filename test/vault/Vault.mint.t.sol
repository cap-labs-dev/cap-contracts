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

        // We should receive less cUSD since USDT is worth more
        assertGe(cUSD.balanceOf(user), amountIn * 98 / 100, "Should have received less cUSD due to higher USDT price");
        assertEq(usdt.balanceOf(address(cUSD)), amountIn, "Vault should have received USDT");
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

    function test_amount_in() public {
        vm.startPrank(env.users.lender_admin);

        cUSD.setFeeData(
            address(usdt),
            IMinter.FeeData({
                minMintFee: 0.005e27,
                slope0: 0,
                slope1: 0,
                mintKinkRatio: 0.85e27,
                burnKinkRatio: 0.15e27,
                optimalRatio: 0.33e27
            })
        );

        vm.startPrank(user);

        // Approve USDT spending
        usdt.mint(user, 100e6);
        usdt.approve(address(cUSD), 100e6);
        cUSD.mint(address(usdt), 10e6, 0, user, block.timestamp + 1 hours);

        // Mint cUSD with USDT
        uint256 amountOut = 1e18;

        uint256 amountIn = cUSD.getMintAmountIn(address(usdt), amountOut);
        console.log(amountIn);

        cUSD.mint(address(usdt), amountIn, 0, user, block.timestamp + 1 hours);
        assertEq(usdt.balanceOf(address(cUSD)), amountIn + 10e6);
    }
}
