// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../../contracts/registry/Registry.sol";
import {Minter} from "../../contracts/minter/Minter.sol";
import {Lender} from "../../contracts/lendingPool/lender/Lender.sol";
import {Vault} from "../../contracts/vault/Vault.sol";
import {CapToken} from "../../contracts/token/CapToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PrincipalDebtToken} from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import {InterestDebtToken} from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import {RestakerDebtToken} from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";
import {CloneLogic} from "../../contracts/lendingPool/libraries/CloneLogic.sol";
import {PriceOracle} from "../../contracts/oracle/PriceOracle.sol";
import {RateOracle} from "../../contracts/oracle/RateOracle.sol";
import {ChainlinkAdapter} from "../../contracts/oracle/libraries/ChainlinkAdapter.sol";
import {AaveAdapter} from "../../contracts/oracle/libraries/AaveAdapter.sol";
import {MockAaveDataProvider} from "../mocks/MockAaveDataProvider.sol";
import {MockChainlink} from "../mocks/MockChainlink.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";

contract GasOptTest is Test {
    Registry public registry;
    Minter public minter;
    Lender public lender;
    Vault public vault;
    CapToken public cUSD;

    PrincipalDebtToken public principalDebtTokenImplementation;
    address public principalDebtTokenInstance;
    InterestDebtToken public interestDebtTokenImplementation;
    address public interestDebtTokenInstance;
    RestakerDebtToken public restakerDebtTokenImplementation;
    address public restakerDebtTokenInstance;

    PriceOracle public priceOracle;
    RateOracle public rateOracle;
    address public aaveAdapter;
    address public chainlinkAdapter;
    MockAaveDataProvider public aaveDataProvider;
    MockChainlink public chainlinkOracle;

    MockCollateral public collateral;

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
        {
            vm.startPrank(user_deployer);
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

            vm.stopPrank();
        }

        // Deploy mock tokens
        {
            vm.startPrank(user_deployer);

            usdt = new MockERC20("USDT", "USDT");
            usdc = new MockERC20("USDC", "USDC");
            usdx = new MockERC20("USDx", "USDx");

            // Mint tokens to minter
            usdt.mint(user_stablecoin_minter, 1000e18);
            usdc.mint(user_stablecoin_minter, 1000e18);
            usdx.mint(user_stablecoin_minter, 1000e18);

            vm.stopPrank();
        }

        // deploy infra contracts
        {
            vm.startPrank(user_deployer);

            // Deploy and initialize Registry
            registry = new Registry();
            registry.initialize();

            // Deploy and initialize Minter with Registry
            minter = new Minter();
            minter.initialize(address(registry));

            // Deploy and initialize Lender with Registry
            lender = new Lender();
            lender.initialize(address(registry));

            // Deploy and initialize Vault with Registry
            vault = new Vault();
            vault.initialize(address(registry));

            // Deploy and initialize cUSD token
            cUSD = new CapToken();
            cUSD.initialize("Capped USD", "cUSD");

            // Deploy debt token
            principalDebtTokenImplementation = new PrincipalDebtToken();
            principalDebtTokenInstance = CloneLogic.initializeBeacon(address(principalDebtTokenImplementation));
            registry.setPrincipalDebtTokenInstance(address(principalDebtTokenInstance));

            // Deploy interest debt token
            interestDebtTokenImplementation = new InterestDebtToken();
            interestDebtTokenInstance = CloneLogic.initializeBeacon(address(interestDebtTokenImplementation));
            registry.setInterestDebtTokenInstance(address(interestDebtTokenInstance));

            // Deploy restaker debt token
            restakerDebtTokenImplementation = new RestakerDebtToken();
            restakerDebtTokenInstance = CloneLogic.initializeBeacon(address(restakerDebtTokenImplementation));
            registry.setRestakerDebtTokenInstance(address(restakerDebtTokenInstance));

            vm.stopPrank();
        }

        // Deploy oracles
        {
            vm.startPrank(user_deployer);

            priceOracle = new PriceOracle();
            priceOracle.initialize(address(registry));

            rateOracle = new RateOracle();
            rateOracle.initialize(address(registry));

            // Deploy adapters libraries
            aaveAdapter = address(AaveAdapter);
            chainlinkAdapter = address(ChainlinkAdapter);

            // Deploy mock data providers
            aaveDataProvider = new MockAaveDataProvider();
            chainlinkOracle = new MockChainlink();

            // Set oracles in registry
            registry.setPriceOracle(address(priceOracle));
            registry.setRateOracle(address(rateOracle));

            vm.stopPrank();
        }

        // Setup roles
        {
            vm.startPrank(user_deployer);

            registry.setAssetManager(user_manager);
            registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), user_deployer);
            registry.grantRole(registry.MANAGER_ROLE(), user_manager);
            cUSD.grantRole(cUSD.MINTER_ROLE(), address(minter));
            cUSD.grantRole(cUSD.BURNER_ROLE(), address(minter));
            vault.grantRole(vault.SUPPLIER_ROLE(), address(minter));
            vault.grantRole(vault.BORROWER_ROLE(), address(lender));

            vm.stopPrank();
        }

        // Set initial oracles data
        {
            vm.startPrank(user_manager);

            chainlinkOracle.setDecimals(8);
            chainlinkOracle.setLatestAnswer(100000000); // $1.00 with 8 decimals

            // Set initial Aave data for USDT
            aaveDataProvider.setReserveData(
                address(usdt),
                0, // unbacked
                0, // accruedToTreasuryScaled
                1000e18, // totalAToken
                1000e18, // totalVariableDebt
                50000000000000000, // liquidityRate (5% APY)
                100000000000000000, // variableBorrowRate (10% APY)
                1e27, // liquidityIndex
                1e27, // variableBorrowIndex
                uint40(block.timestamp)
            );

            vm.stopPrank();
        }

        // Setup price sources and adapters
        {
            vm.startPrank(user_manager);

            // Set Chainlink as price source for stablecoins
            priceOracle.setAdapter(address(chainlinkOracle), address(chainlinkAdapter));
            priceOracle.setSource(address(usdt), address(chainlinkOracle));
            priceOracle.setSource(address(usdc), address(chainlinkOracle));
            priceOracle.setSource(address(usdx), address(chainlinkOracle));

            // Set Aave as rate source
            rateOracle.setAdapter(address(aaveDataProvider), address(aaveAdapter));
            rateOracle.setSource(address(usdt), address(aaveDataProvider));
            rateOracle.setSource(address(usdc), address(aaveDataProvider));
            rateOracle.setSource(address(usdx), address(aaveDataProvider));

            // Set initial prices (1:1 for simplicity)
            chainlinkOracle.setLatestAnswer(100000000); // $1.00 for all stablecoins

            vm.stopPrank();
        }

        // Setup minter, lender and collateral
        {
            vm.startPrank(user_deployer);

            collateral = new MockCollateral();
            registry.setCollateral(address(collateral));

            registry.setMinter(address(minter));

            registry.setLender(address(lender));

            vm.stopPrank();
        }

        // Setup vault assets
        {
            vm.startPrank(user_manager);

            // update the registry with the new basket
            registry.setBasket(address(cUSD), address(vault), 0); // No base fee for testing
            registry.addAsset(address(cUSD), address(usdt));
            registry.addAsset(address(cUSD), address(usdc));
            registry.addAsset(address(cUSD), address(usdx));

            vm.stopPrank();
        }

        // have something in the vault already
        {
            vm.startPrank(user_deployer);

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

        // allow agents to borrow any assets
        {
            vm.startPrank(user_manager);
            lender.addAsset(address(usdc), address(vault), 1e18);
            lender.addAsset(address(usdt), address(vault), 1e18);
            lender.addAsset(address(usdx), address(vault), 1e18);
            vm.stopPrank();
        }

        // make the agent covered
        {
            vm.startPrank(user_manager);
            collateral.setCoverage(user_agent, 100000e18);
            collateral.setLtv(user_agent, 1e18);
            vm.stopPrank();
        }
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
        chainlinkOracle.setLatestAnswer(102e8);

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

    function testAgentBorrow() public {
        vm.startPrank(user_agent);

        address borrowAsset = address(usdc);
        uint256 borrowAmount = 1e18; // mock usdc has 18 decimals
        address receiver = user_agent;

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        lender.borrow(borrowAsset, borrowAmount, receiver);
        assertEq(usdc.balanceOf(receiver), borrowAmount);

        //simulate yield
        usdc.mint(user_agent, 1000e18);

        // repay the debt
        uint256 interest = 10;
        usdc.approve(address(lender), borrowAmount + interest);
        lender.repay(borrowAsset, borrowAmount, user_agent);
        assertGe(usdc.balanceOf(address(vault)), vaultBalanceBefore);

        vm.stopPrank();
    }

    function testPriceOracle() public view {
        uint256 usdtPrice = priceOracle.getPrice(address(usdt));
        assertEq(usdtPrice, 1e8, "USDT price should be $1");
    }

    function testRateOracle() public view {
        uint256 usdtRate = rateOracle.marketRate(address(usdt));
        assertEq(usdtRate, 1e17, "USDT borrow rate should be 10%, 1e18 being 100%");
    }
}
