pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Registry} from "../contracts/registry/Registry.sol";
import {Minter} from "../contracts/minter/Minter.sol";
import {Lender} from "../contracts/lendingPool/lender/Lender.sol";
import {Vault} from "../contracts/vault/Vault.sol";
import {CapToken} from "../contracts/token/CapToken.sol";
import {DebtToken} from "../contracts/lendingPool/tokens/DebtToken.sol";
import {InterestDebtToken} from "../contracts/lendingPool/tokens/InterestDebtToken.sol";
import {RestakerDebtToken} from "../contracts/lendingPool/tokens/RestakerDebtToken.sol";
import {CloneLogic} from "../contracts/lendingPool/libraries/CloneLogic.sol";
import {PriceOracle} from "../contracts/oracle/PriceOracle.sol";
import {RateOracle} from "../contracts/oracle/RateOracle.sol";
import {ChainlinkAdapter} from "../contracts/oracle/libraries/ChainlinkAdapter.sol";
import {AaveAdapter} from "../contracts/oracle/libraries/AaveAdapter.sol";
import {MockAaveDataProvider} from "../test/mocks/MockAaveDataProvider.sol";
import {MockChainlink} from "../test/mocks/MockChainlink.sol";
import {MockCollateral} from "../test/mocks/MockCollateral.sol";

contract DeployTestnetVault is Script {
    Registry public registry;
    Minter public minter;
    Lender public lender;
    Vault public vault;
    CapToken public cUSD;

    DebtToken public debtTokenImplementation;
    address public debtTokenInstance;
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
    MockERC20 public weth;

    function run() external {
        vm.startBroadcast();

        // Get the broadcast address (deployer's address)
        address user_deployer = msg.sender;
        address user_agent = msg.sender;

        // Deploy mock tokens
        {
            usdt = new MockERC20("USDT", "USDT");
            usdc = new MockERC20("USDC", "USDC");
            usdx = new MockERC20("USDx", "USDx");

            // Print mock token addresses
            console.log("Mock USDT address:", address(usdt));
            console.log("Mock USDC address:", address(usdc));
            console.log("Mock USDx address:", address(usdx));

            // Mint tokens to minter
            usdt.mint(user_deployer, 1000e18);
            usdc.mint(user_deployer, 1000e18);
            usdx.mint(user_deployer, 1000e18);
        }

        // deploy infra contracts
        {
            // Deploy and initialize Registry
            registry = new Registry();
            registry.initialize();
            console.log("Registry address:", address(registry));

            // Deploy and initialize Minter with Registry
            minter = new Minter();
            minter.initialize(address(registry));
            console.log("Minter address:", address(minter));

            // Deploy and initialize Lender with Registry
            lender = new Lender();
            lender.initialize(address(registry));
            console.log("Lender address:", address(lender));

            // Deploy and initialize Vault with Registry
            vault = new Vault();
            vault.initialize(address(registry));
            console.log("Vault address:", address(vault));

            // Deploy and initialize cUSD token
            cUSD = new CapToken();
            cUSD.initialize("Capped USD", "cUSD");
            console.log("cUSD address:", address(cUSD));

            // Deploy debt tokens
            debtTokenImplementation = new DebtToken();
            debtTokenInstance = CloneLogic.initializeBeacon(address(debtTokenImplementation));
            registry.setDebtTokenInstance(address(debtTokenInstance));
            console.log("Debt Token Implementation:", address(debtTokenImplementation));
            console.log("Debt Token Instance:", debtTokenInstance);

            interestDebtTokenImplementation = new InterestDebtToken();
            interestDebtTokenInstance = CloneLogic.initializeBeacon(address(interestDebtTokenImplementation));
            registry.setInterestDebtTokenInstance(address(interestDebtTokenInstance));
            console.log("Interest Debt Token Implementation:", address(interestDebtTokenImplementation));
            console.log("Interest Debt Token Instance:", interestDebtTokenInstance);

            restakerDebtTokenImplementation = new RestakerDebtToken();
            restakerDebtTokenInstance = CloneLogic.initializeBeacon(address(restakerDebtTokenImplementation));
            registry.setRestakerDebtTokenInstance(address(restakerDebtTokenInstance));
            console.log("Restaker Debt Token Implementation:", address(restakerDebtTokenImplementation));
            console.log("Restaker Debt Token Instance:", restakerDebtTokenInstance);
        }

        // deploy oracles
        {
            // Deploy oracles and adapters
            priceOracle = new PriceOracle();
            priceOracle.initialize(address(registry));
            console.log("Price Oracle address:", address(priceOracle));

            rateOracle = new RateOracle();
            rateOracle.initialize(address(registry));
            console.log("Rate Oracle address:", address(rateOracle));

            aaveAdapter = address(AaveAdapter);
            chainlinkAdapter = address(ChainlinkAdapter);
            console.log("Aave Adapter address:", aaveAdapter);
            console.log("Chainlink Adapter address:", chainlinkAdapter);

            // Deploy mock data providers
            aaveDataProvider = new MockAaveDataProvider();
            chainlinkOracle = new MockChainlink();
            console.log("Aave Data Provider address:", address(aaveDataProvider));
            console.log("Chainlink Oracle address:", address(chainlinkOracle));

            // Set oracles in registry
            registry.setPriceOracle(address(priceOracle));
            registry.setRateOracle(address(rateOracle));
        }

        // Setup roles
        {
            registry.setAssetManager(user_deployer);
            registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), user_deployer);
            registry.grantRole(registry.MANAGER_ROLE(), user_deployer);
            cUSD.grantRole(cUSD.MINTER_ROLE(), address(minter));
            cUSD.grantRole(cUSD.BURNER_ROLE(), address(minter));
            vault.grantRole(vault.SUPPLIER_ROLE(), address(minter));
            vault.grantRole(vault.BORROWER_ROLE(), address(lender));
        }

        // Set initial oracles data
        {
            // Set initial oracles data
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
        }

        // Setup price sources and adapters
        {
            // Setup price sources and adapters
            priceOracle.setAdapter(address(chainlinkOracle), address(ChainlinkAdapter));
            priceOracle.setSource(address(usdt), address(chainlinkOracle));
            priceOracle.setSource(address(usdc), address(chainlinkOracle));
            priceOracle.setSource(address(usdx), address(chainlinkOracle));

            // Set Aave as rate source
            rateOracle.setAdapter(address(aaveDataProvider), address(AaveAdapter));
            rateOracle.setSource(address(usdt), address(aaveDataProvider));
            rateOracle.setSource(address(usdc), address(aaveDataProvider));
            rateOracle.setSource(address(usdx), address(aaveDataProvider));

            // set initial prices
            chainlinkOracle.setLatestAnswer(100000000); // $1.00 for all stablecoins
        }

        // Setup minter, lender and collateral
        {
            // Deploy and setup mock collateral
            collateral = new MockCollateral();
            registry.setCollateral(address(collateral));
            console.log("Collateral address:", address(collateral));

            // Set minter in registry
            registry.setMinter(address(minter));
            registry.setLender(address(lender));
        }

        // Setup vault assets
        {
            // update the registry with the new basket
            registry.setBasket(address(cUSD), address(vault), 0); // No base fee for testing
            registry.addAsset(address(cUSD), address(usdt));
            registry.addAsset(address(cUSD), address(usdc));
            registry.addAsset(address(cUSD), address(usdx));
        }

        // have something in the vault already
        {
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
        }

        // Allow agents to borrow any assets
        {
            lender.addAsset(address(usdc), address(vault), 1e18);
            lender.addAsset(address(usdt), address(vault), 1e18);
            lender.addAsset(address(usdx), address(vault), 1e18);
        }

        // Make the agent covered
        {
            collateral.setCoverage(user_agent, 100000e18);
            collateral.setLtv(user_agent, 1e18);
        }

        vm.stopBroadcast();
    }
}
