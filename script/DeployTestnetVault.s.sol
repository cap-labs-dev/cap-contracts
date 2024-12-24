pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockOracle} from "../test/mocks/MockOracle.sol";
import {Registry} from "../contracts/registry/Registry.sol";
import {Minter} from "../contracts/minter/Minter.sol";
import {Vault} from "../contracts/minter/Vault.sol";
import {CapToken} from "../contracts/token/CapToken.sol";

contract DeployTestnetVault is Script {
    function run() external {
        vm.startBroadcast();
        // Get the broadcast address (deployer's address)
        address user_deployer = msg.sender;

        // Deploy mock tokens
        MockERC20 usdt = new MockERC20("USDT", "USDT");
        MockERC20 usdc = new MockERC20("USDC", "USDC");
        MockERC20 usdx = new MockERC20("USDx", "USDx");

        // Print mock token addresses
        console.log("Mock USDT address:", address(usdt));
        console.log("Mock USDC address:", address(usdc));
        console.log("Mock USDx address:", address(usdx));

        // Mint tokens to minter
        usdt.mint(user_deployer, 1000e18);
        usdc.mint(user_deployer, 1000e18);
        usdx.mint(user_deployer, 1000e18);

        // Deploy and initialize Registry
        Registry registry = new Registry();
        registry.initialize();
        console.log("Registry address:", address(registry));

        // Deploy and initialize Minter with Registry
        Minter minter = new Minter();
        minter.initialize(address(registry));
        console.log("Minter address:", address(minter));

        // Deploy and initialize Vault with Registry
        Vault vault = new Vault();
        vault.initialize(address(registry));
        console.log("Vault address:", address(vault));

        // Deploy and initialize cUSD token
        CapToken cUSD = new CapToken();
        cUSD.initialize("Capped USD", "cUSD");
        console.log("cUSD address:", address(cUSD));

        // Deploy and setup mock oracle
        MockOracle oracle = new MockOracle();
        registry.setOracle(address(oracle));
        console.log("Mock Oracle address:", address(oracle));

        // Setup initial prices (1:1 for simplicity)
        oracle.setPrice(address(usdt), 1e18);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(usdx), 1e18);

        // Setup roles
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), user_deployer);
        registry.grantRole(registry.MANAGER_ROLE(), user_deployer);
        cUSD.grantRole(cUSD.MINTER_ROLE(), address(minter));
        cUSD.grantRole(cUSD.BURNER_ROLE(), address(minter));
        vault.grantRole(vault.SUPPLIER_ROLE(), address(minter));

        // update the registry with the new basket
        registry.setBasket(address(cUSD), address(vault), 0); // No base fee for testing
        registry.addAsset(address(cUSD), address(usdt));
        registry.addAsset(address(cUSD), address(usdc));
        registry.addAsset(address(cUSD), address(usdx));

        // Set minter in registry
        registry.setMinter(address(minter));

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

        vm.stopBroadcast();
    }
}
