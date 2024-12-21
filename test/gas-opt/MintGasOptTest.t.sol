// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../../contracts/registry/Registry.sol";
import {Minter} from "../../contracts/minter/Minter.sol";
import {Vault} from "../../contracts/minter/Vault.sol";
import {CapToken} from "../../contracts/token/CapToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MintGasOptTest is Test {
    Registry public registry;
    Minter public minter;
    Vault public vault;
    CapToken public cUSD;
    MockOracle public oracle;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public usdx;

    address public user_deployer;
    address public user_admin;
    address public user_manager;
    address public user_agent;
    address[10] public stablecoin_minters;

    function setUp() public {
        // Setup addresses with gas
        user_deployer = makeAddr("deployer");
        user_admin = makeAddr("admin");
        user_manager = makeAddr("manager");
        user_agent = makeAddr("agent");

        // Setup 10 stablecoin minters
        for (uint256 i = 0; i < 10; i++) {
            string memory minterNum = vm.toString(i);
            stablecoin_minters[i] = makeAddr(string.concat("minter", minterNum));
            vm.deal(stablecoin_minters[i], 100 ether);
        }

        vm.deal(user_deployer, 100 ether);
        vm.deal(user_admin, 100 ether);
        vm.deal(user_manager, 100 ether);
        vm.deal(user_agent, 100 ether);

        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT");
        usdc = new MockERC20("USDC", "USDC");
        usdx = new MockERC20("USDx", "USDx");

        // Mint tokens to all minters
        for (uint256 i = 0; i < 10; i++) {
            usdt.mint(stablecoin_minters[i], 1000e18);
            usdc.mint(stablecoin_minters[i], 1000e18);
            usdx.mint(stablecoin_minters[i], 1000e18);
        }

        vm.startPrank(user_deployer);

        // Deploy and initialize Registry
        registry = new Registry();
        registry.initialize();

        // Deploy and initialize Minter with Registry
        minter = new Minter();
        minter.initialize(address(registry));

        // Deploy and initialize Vault with Registry
        vault = new Vault();
        vault.initialize(address(registry));

        // Deploy and initialize cUSD token
        cUSD = new CapToken();
        cUSD.initialize("Capped USD", "cUSD");

        // Deploy and setup mock oracle
        oracle = new MockOracle();
        registry.setOracle(address(oracle));

        // Setup initial prices (1:1 for simplicity)
        oracle.setPrice(address(usdt), 1e18);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(usdx), 1e18);

        // Setup roles
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), user_deployer);
        registry.grantRole(registry.MANAGER_ROLE(), user_manager);
        cUSD.grantRole(cUSD.MINTER_ROLE(), address(minter));
        vault.grantRole(vault.SUPPLIER_ROLE(), address(minter));

        vm.stopPrank();

        // Setup Registry with manager role
        vm.startPrank(user_manager);

        // update the registry with the new basket
        registry.setBasket(address(cUSD), address(vault), 0); // No base fee for testing
        registry.addAsset(address(cUSD), address(usdt));
        registry.addAsset(address(cUSD), address(usdc));
        registry.addAsset(address(cUSD), address(usdx));

        // Set minter in registry
        registry.setMinter(address(minter));

        vm.stopPrank();
    }

    function testMintWithUSDT() public {
        vm.startPrank(stablecoin_minters[0]);

        // Approve USDT spending
        usdt.approve(address(minter), 100e18);

        // Mint cUSD with USDT
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        minter.swapExactTokenForTokens(
            amountIn, minAmountOut, address(usdt), address(cUSD), stablecoin_minters[0], deadline
        );

        // Assert the minting was successful
        assertGt(cUSD.balanceOf(stablecoin_minters[0]), 0, "Should have received cUSD tokens");
        assertEq(usdt.balanceOf(address(vault)), amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testMintWithDifferentPrices() public {
        vm.startPrank(stablecoin_minters[0]);

        // Set USDT price to 1.02 USD
        oracle.setPrice(address(usdt), 1.02e18);

        // Approve USDT spending
        usdt.approve(address(minter), 100e18);

        // Mint cUSD with USDT
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 95e18;
        uint256 deadline = block.timestamp + 1 hours;

        minter.swapExactTokenForTokens(
            amountIn, minAmountOut, address(usdt), address(cUSD), stablecoin_minters[0], deadline
        );

        // We should receive more cUSD since USDT is worth more
        uint256 expectedMin = (amountIn * 102) / 100; // rough calculation
        assertGe(
            cUSD.balanceOf(stablecoin_minters[0]),
            expectedMin,
            "Should have received more cUSD due to higher USDT price"
        );
        assertEq(usdt.balanceOf(address(vault)), amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testParallelMinting() public {
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 95e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Have all minters approve and mint simultaneously
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(stablecoin_minters[i]);

            // Approve USDT spending
            usdt.approve(address(minter), amountIn);

            // Mint cUSD with USDT
            minter.swapExactTokenForTokens(
                amountIn, minAmountOut, address(usdt), address(cUSD), stablecoin_minters[i], deadline
            );

            // Assert the minting was successful
            assertGt(cUSD.balanceOf(stablecoin_minters[i]), 0, "Should have received cUSD tokens");

            vm.stopPrank();
        }

        // Assert total USDT in vault
        assertEq(
            usdt.balanceOf(address(vault)), amountIn * 10, "Vault should have received total USDT from all minters"
        );
    }
}
