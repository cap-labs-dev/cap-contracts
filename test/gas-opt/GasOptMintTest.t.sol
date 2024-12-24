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

contract GasOptMintTest is Test {
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
    address public user_stablecoin_minter;

    function setUp() public {
        // Setup addresses with gas
        user_deployer = makeAddr("deployer");
        user_admin = makeAddr("admin");
        user_manager = makeAddr("manager");
        user_agent = makeAddr("agent");
        user_stablecoin_minter = makeAddr("stablecoin_minter");

        // Setup 10 stablecoin minters
        vm.deal(user_deployer, 100 ether);
        vm.deal(user_admin, 100 ether);
        vm.deal(user_manager, 100 ether);
        vm.deal(user_agent, 100 ether);
        vm.deal(user_stablecoin_minter, 100 ether);

        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT");
        usdc = new MockERC20("USDC", "USDC");
        usdx = new MockERC20("USDx", "USDx");

        // Mint tokens to minter
        usdt.mint(user_stablecoin_minter, 1000e18);
        usdc.mint(user_stablecoin_minter, 1000e18);
        usdx.mint(user_stablecoin_minter, 1000e18);

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
        cUSD.grantRole(cUSD.BURNER_ROLE(), address(minter));
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

        vm.startPrank(user_deployer);

        // have something in the vault already
        vault.grantRole(vault.SUPPLIER_ROLE(), address(user_deployer));
        usdt.mint(address(user_deployer), 1000e18);
        usdc.mint(address(user_deployer), 1000e18);
        usdx.mint(address(user_deployer), 1000e18);
        usdt.approve(address(vault), 1000e18);
        usdc.approve(address(vault), 1000e18);
        usdx.approve(address(vault), 1000e18);
        vault.deposit(address(usdt), 1000e18);
        vault.deposit(address(usdc), 1000e18);
        vault.deposit(address(usdx), 1000e18);
        vault.revokeRole(vault.SUPPLIER_ROLE(), address(user_deployer));
        cUSD.grantRole(cUSD.MINTER_ROLE(), address(user_deployer));
        cUSD.mint(address(user_deployer), 3000e18);
        cUSD.revokeRole(cUSD.MINTER_ROLE(), address(user_deployer));

        vm.stopPrank();
    }

    function testMintWithUSDT() public {
        vm.startPrank(user_stablecoin_minter);

        uint256 vaultBalanceBefore = usdt.balanceOf(address(vault));

        // Approve USDT spending
        usdt.approve(address(minter), 100e18);

        // Mint cUSD with USDT
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 95e18; // Accounting for potential fees
        uint256 deadline = block.timestamp + 1 hours;

        minter.swapExactTokenForTokens(
            amountIn, minAmountOut, address(usdt), address(cUSD), user_stablecoin_minter, deadline
        );

        // Assert the minting was successful
        assertGt(cUSD.balanceOf(user_stablecoin_minter), 0, "Should have received cUSD tokens");
        assertEq(usdt.balanceOf(address(vault)), vaultBalanceBefore + amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testMintWithDifferentPrices() public {
        vm.startPrank(user_stablecoin_minter);

        uint256 vaultBalanceBefore = usdt.balanceOf(address(vault));

        // Set USDT price to 1.02 USD
        oracle.setPrice(address(usdt), 1.02e18);

        // Approve USDT spending
        usdt.approve(address(minter), 100e18);

        // Mint cUSD with USDT
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 90e18;
        uint256 deadline = block.timestamp + 1 hours;

        minter.swapExactTokenForTokens(
            amountIn, minAmountOut, address(usdt), address(cUSD), user_stablecoin_minter, deadline
        );

        // We should receive less cUSD since USDT is worth more
        assertGe(
            cUSD.balanceOf(user_stablecoin_minter),
            amountIn * 98 / 100,
            "Should have received less cUSD due to higher USDT price"
        );
        assertEq(usdt.balanceOf(address(vault)), vaultBalanceBefore + amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testMintAndBurn() public {
        vm.startPrank(user_stablecoin_minter);

        // Initial balances
        uint256 initialUsdtBalance = usdt.balanceOf(user_stablecoin_minter);
        uint256 initialVaultBalance = usdt.balanceOf(address(vault));

        // First mint cUSD with USDT
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 95e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Approve and mint
        usdt.approve(address(minter), amountIn);
        minter.swapExactTokenForTokens(
            amountIn, minAmountOut, address(usdt), address(cUSD), user_stablecoin_minter, deadline
        );

        uint256 mintedAmount = cUSD.balanceOf(user_stablecoin_minter);
        assertGt(mintedAmount, 0, "Should have received cUSD tokens");
        assertEq(usdt.balanceOf(address(vault)), initialVaultBalance + amountIn, "Vault should have received USDT");

        // Now burn the cUSD tokens
        uint256 burnAmount = mintedAmount;
        uint256 minOutputAmount = burnAmount * 95 / 100; // Expect at least 95% back accounting for potential fees

        cUSD.approve(address(minter), burnAmount);
        minter.swapExactTokenForTokens(
            burnAmount, minOutputAmount, address(cUSD), address(usdt), user_stablecoin_minter, deadline
        );

        // Verify final balances
        assertEq(cUSD.balanceOf(user_stablecoin_minter), 0, "Should have burned all cUSD tokens");
        assertGt(
            usdt.balanceOf(user_stablecoin_minter),
            initialUsdtBalance - amountIn + minOutputAmount,
            "Should have received USDT back"
        );

        vm.stopPrank();
    }
}
