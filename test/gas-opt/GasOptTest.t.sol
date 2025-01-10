// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CloneLogic} from "../../contracts/lendingPool/libraries/CloneLogic.sol";
import {AccessControl} from "../../contracts/registry/AccessControl.sol";
import {AddressProvider} from "../../contracts/registry/AddressProvider.sol";
import {VaultDataProvider} from "../../contracts/registry/VaultDataProvider.sol";
import {IVaultDataProvider} from "../../contracts/interfaces/IVaultDataProvider.sol";
import {Minter} from "../../contracts/minter/Minter.sol";
import {Lender} from "../../contracts/lendingPool/lender/Lender.sol";
import {Vault} from "../../contracts/vault/Vault.sol";
import {CapToken} from "../../contracts/token/CapToken.sol";
import {StakedCap} from "../../contracts/token/StakedCap.sol";
import {IStakedCap} from "../../contracts/interfaces/IStakedCap.sol";
import {PrincipalDebtToken} from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import {InterestDebtToken} from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import {RestakerDebtToken} from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";
import {PriceOracle} from "../../contracts/oracle/PriceOracle.sol";
import {RateOracle} from "../../contracts/oracle/RateOracle.sol";
import {IAddressProvider} from "../../contracts/interfaces/IAddressProvider.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {IRateOracle} from "../../contracts/interfaces/IRateOracle.sol";
import {ChainlinkAdapter} from "../../contracts/oracle/libraries/ChainlinkAdapter.sol";
import {AaveAdapter} from "../../contracts/oracle/libraries/AaveAdapter.sol";
import {CapTokenAdapter} from "../../contracts/oracle/libraries/CapTokenAdapter.sol";
import {StakedCapAdapter} from "../../contracts/oracle/libraries/StakedCapAdapter.sol";
import {MockAaveDataProvider} from "../mocks/MockAaveDataProvider.sol";
import {MockChainlinkPriceFeed} from "../mocks/MockChainlinkPriceFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";

contract GasOptTest is Test {
    AccessControl public accessControlProviderImplementation;
    AccessControl public accessControlProvider;
    AddressProvider public addressProviderImplementation;
    AddressProvider public addressProvider;
    VaultDataProvider public vaultDataProviderImplementation;
    VaultDataProvider public vaultDataProvider;
    Minter public minterImplementation;
    Minter public minter;
    Lender public lenderImplementation;
    Lender public lender;

    CapToken public cUSD;
    Vault public cUSDVault;
    StakedCap public scUSD;

    CapToken public capTokenImplementation;
    Vault public vaultImplementation;
    StakedCap public stakedCapImplementation;
    PrincipalDebtToken public principalDebtTokenImplementation;
    InterestDebtToken public interestDebtTokenImplementation;
    RestakerDebtToken public restakerDebtTokenImplementation;
    address public capTokenBeacon;
    address public vaultBeacon;
    address public stakedCapBeacon;
    address public principalDebtTokenBeacon;
    address public interestDebtTokenBeacon;
    address public restakerDebtTokenBeacon;

    PriceOracle public priceOracleImplementation;
    PriceOracle public priceOracle;
    RateOracle public rateOracleImplementation;
    RateOracle public rateOracle;
    address public aaveAdapter;
    address public chainlinkAdapter;
    address public capTokenAdapter;
    address public stakedCapAdapter;
    MockAaveDataProvider public usdtAaveDataProvider;
    MockAaveDataProvider public usdcAaveDataProvider;
    MockAaveDataProvider public usdxAaveDataProvider;
    MockChainlinkPriceFeed public usdtChainlinkPriceFeed;
    MockChainlinkPriceFeed public usdcChainlinkPriceFeed;
    MockChainlinkPriceFeed public usdxChainlinkPriceFeed;

    MockCollateral public collateral;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public usdx;

    address public user_deployer;
    address public user_agent;
    address public user_stablecoin_minter;
    address public user_liquidator;

    address public user_access_control_admin;
    address public user_address_provider_admin;
    address public user_vault_keeper;
    address public user_vault_data_admin;
    address public user_price_oracle_admin;
    address public user_rate_oracle_admin;
    address public user_cap_tokens_admin;
    address public user_vaults_admin;
    address public user_lender_admin;

    function setUp() public {
        // Setup addresses with gas
        {
            vm.startPrank(user_deployer);
            user_deployer = makeAddr("deployer");
            user_agent = makeAddr("agent");
            user_stablecoin_minter = makeAddr("stablecoin_minter");
            user_liquidator = makeAddr("liquidator");
            user_access_control_admin = makeAddr("access_control_admin");
            user_address_provider_admin = makeAddr("address_provider_admin");
            user_vault_keeper = makeAddr("vault_keeper");
            user_vault_data_admin = makeAddr("vault_data_admin");
            user_price_oracle_admin = makeAddr("user_price_oracle_admin");
            user_rate_oracle_admin = makeAddr("user_rate_oracle_admin");
            user_cap_tokens_admin = makeAddr("user_cap_tokens_admin");
            user_lender_admin = makeAddr("user_lender_admin");
            user_vaults_admin = makeAddr("user_vaults_admin");
            // Give gas to all users
            vm.deal(user_deployer, 100 ether);
            vm.deal(user_agent, 100 ether);
            vm.deal(user_stablecoin_minter, 100 ether);
            vm.deal(user_liquidator, 100 ether);
            vm.deal(user_access_control_admin, 100 ether);
            vm.deal(user_address_provider_admin, 100 ether);
            vm.deal(user_vault_keeper, 100 ether);
            vm.deal(user_vault_data_admin, 100 ether);
            vm.deal(user_price_oracle_admin, 100 ether);
            vm.deal(user_rate_oracle_admin, 100 ether);
            vm.deal(user_lender_admin, 100 ether);
            vm.deal(user_cap_tokens_admin, 100 ether);
            vm.deal(user_vaults_admin, 100 ether);
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

            // mint some tokens to the liquidator for repayments
            usdt.mint(user_liquidator, 1000e18);
            usdc.mint(user_liquidator, 1000e18);
            usdx.mint(user_liquidator, 1000e18);

            vm.stopPrank();
        }

        // deploy core infra contracts
        {
            vm.startPrank(user_deployer);

            bytes memory _empty = "";
            // Deploy and initialize Registry contracts
            accessControlProviderImplementation = new AccessControl();
            accessControlProvider =
                AccessControl(address(new ERC1967Proxy(address(accessControlProviderImplementation), _empty)));
            accessControlProvider.initialize(user_access_control_admin);

            addressProviderImplementation = new AddressProvider();
            addressProvider = AddressProvider(address(new ERC1967Proxy(address(addressProviderImplementation), _empty)));
            addressProvider.initialize(address(accessControlProvider));

            vaultDataProviderImplementation = new VaultDataProvider();
            vaultDataProvider =
                VaultDataProvider(address(new ERC1967Proxy(address(vaultDataProviderImplementation), _empty)));
            vaultDataProvider.initialize(address(addressProvider));

            minterImplementation = new Minter();
            minter = Minter(address(new ERC1967Proxy(address(minterImplementation), _empty)));
            minter.initialize(address(addressProvider));

            lenderImplementation = new Lender();
            lender = Lender(address(new ERC1967Proxy(address(lenderImplementation), _empty)));
            lender.initialize(address(addressProvider));

            capTokenImplementation = new CapToken();
            capTokenBeacon = CloneLogic.initializeBeacon(address(capTokenImplementation));

            vaultImplementation = new Vault();
            vaultBeacon = CloneLogic.initializeBeacon(address(vaultImplementation));

            stakedCapImplementation = new StakedCap();
            stakedCapBeacon = CloneLogic.initializeBeacon(address(stakedCapImplementation));

            principalDebtTokenImplementation = new PrincipalDebtToken();
            principalDebtTokenBeacon = CloneLogic.initializeBeacon(address(principalDebtTokenImplementation));

            interestDebtTokenImplementation = new InterestDebtToken();
            interestDebtTokenBeacon = CloneLogic.initializeBeacon(address(interestDebtTokenImplementation));

            restakerDebtTokenImplementation = new RestakerDebtToken();
            restakerDebtTokenBeacon = CloneLogic.initializeBeacon(address(restakerDebtTokenImplementation));

            collateral = new MockCollateral();

            vm.stopPrank();
        }

        // Deploy oracles
        {
            vm.startPrank(user_deployer);

            bytes memory _empty = "";
            priceOracleImplementation = new PriceOracle();
            priceOracle = PriceOracle(address(new ERC1967Proxy(address(priceOracleImplementation), _empty)));
            priceOracle.initialize(address(addressProvider));

            rateOracleImplementation = new RateOracle();
            rateOracle = RateOracle(address(new ERC1967Proxy(address(rateOracleImplementation), _empty)));
            rateOracle.initialize(address(addressProvider));

            // Deploy adapters libraries
            aaveAdapter = address(AaveAdapter);
            chainlinkAdapter = address(ChainlinkAdapter);
            capTokenAdapter = address(CapTokenAdapter);
            stakedCapAdapter = address(StakedCapAdapter);

            // Deploy mock data providers
            usdtAaveDataProvider = new MockAaveDataProvider();
            usdcAaveDataProvider = new MockAaveDataProvider();
            usdxAaveDataProvider = new MockAaveDataProvider();
            usdtChainlinkPriceFeed = new MockChainlinkPriceFeed();
            usdcChainlinkPriceFeed = new MockChainlinkPriceFeed();
            usdxChainlinkPriceFeed = new MockChainlinkPriceFeed();

            vm.stopPrank();
        }

        // Setup access control roles
        {
            vm.startPrank(user_access_control_admin);

            accessControlProvider.grantRole(addressProvider.ADDRESS_PROVIDER_ADMIN(), user_address_provider_admin);
            accessControlProvider.grantRole(vaultDataProvider.VAULT_DATA_ADMIN(), user_vault_data_admin);
            accessControlProvider.grantRole(vaultDataProvider.VAULT_DATA_KEEPER(), user_vault_keeper);
            accessControlProvider.grantRole(priceOracle.PRICE_ORACLE_ADMIN(), user_price_oracle_admin);
            accessControlProvider.grantRole(rateOracle.RATE_ORACLE_ADMIN(), user_rate_oracle_admin);
            accessControlProvider.grantRole(lender.LENDER_ADMIN(), user_lender_admin);

            accessControlProvider.grantRole(vaultImplementation.VAULT_ADMIN(), user_vaults_admin);
            accessControlProvider.grantRole(vaultImplementation.VAULT_SUPPLIER(), address(minter));
            accessControlProvider.grantRole(vaultImplementation.VAULT_BORROWER(), address(lender));

            accessControlProvider.grantRole(capTokenImplementation.CAP_ADMIN(), user_cap_tokens_admin);
            accessControlProvider.grantRole(capTokenImplementation.CAP_MINTER(), address(minter));
            accessControlProvider.grantRole(capTokenImplementation.CAP_BURNER(), address(minter));

            vm.stopPrank();
        }

        // initialize the address provider contract addresses
        {
            vm.startPrank(user_address_provider_admin);

            addressProvider.setAccessControl(address(accessControlProvider));
            addressProvider.setVaultDataProvider(address(vaultDataProvider));

            addressProvider.setPriceOracle(address(priceOracle));
            addressProvider.setRateOracle(address(rateOracle));
            addressProvider.setCollateral(address(collateral));

            addressProvider.setMinter(address(minter));
            addressProvider.setLender(address(lender));

            addressProvider.setCapTokenInstance(capTokenBeacon);
            addressProvider.setVaultInstance(vaultBeacon);
            addressProvider.setStakedCapInstance(stakedCapBeacon);
            addressProvider.setPrincipalDebtTokenInstance(principalDebtTokenBeacon);
            addressProvider.setInterestDebtTokenInstance(interestDebtTokenBeacon);
            addressProvider.setRestakerDebtTokenInstance(restakerDebtTokenBeacon);

            vm.stopPrank();
        }

        // Set initial oracles data
        {
            vm.startPrank(user_vault_data_admin);

            usdtChainlinkPriceFeed.setDecimals(8);
            usdcChainlinkPriceFeed.setDecimals(8);
            usdxChainlinkPriceFeed.setDecimals(8);
            usdtChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals
            usdcChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals
            usdxChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals

            // Set initial Aave data for USDT
            usdtAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%
            usdcAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%
            usdxAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%

            vm.stopPrank();
        }

        // Setup price sources and adapters
        {
            vm.startPrank(user_price_oracle_admin);

            // Set Chainlink as price source for stablecoins
            priceOracle.setOracleData(
                address(usdt),
                PriceOracle.OracleData({
                    adapter: address(chainlinkAdapter),
                    payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdtChainlinkPriceFeed))
                })
            );
            priceOracle.setOracleData(
                address(usdc),
                PriceOracle.OracleData({
                    adapter: address(chainlinkAdapter),
                    payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdcChainlinkPriceFeed))
                })
            );
            priceOracle.setOracleData(
                address(usdx),
                PriceOracle.OracleData({
                    adapter: address(chainlinkAdapter),
                    payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdxChainlinkPriceFeed))
                })
            );

            vm.stopPrank();
        }

        // Set Aave as rate source
        {
            vm.startPrank(user_rate_oracle_admin);

            rateOracle.setOracleData(
                address(usdt),
                RateOracle.OracleData({
                    adapter: address(aaveAdapter),
                    payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdtAaveDataProvider), address(usdt))
                })
            );
            rateOracle.setOracleData(
                address(usdc),
                RateOracle.OracleData({
                    adapter: address(aaveAdapter),
                    payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdcAaveDataProvider), address(usdc))
                })
            );
            rateOracle.setOracleData(
                address(usdx),
                RateOracle.OracleData({
                    adapter: address(aaveAdapter),
                    payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdxAaveDataProvider), address(usdx))
                })
            );

            vm.stopPrank();
        }

        // Setup cUSD
        {
            vm.startPrank(user_vault_data_admin);

            cUSD = CapToken(CloneLogic.clone(capTokenBeacon));
            cUSD.initialize(address(addressProvider), "Capped USD", "cUSD");

            scUSD = StakedCap(CloneLogic.clone(stakedCapBeacon));
            scUSD.initialize(address(addressProvider), address(cUSD));

            // update the registry with the new basket
            address[] memory assets = new address[](3);
            VaultDataProvider.AllocationData[] memory allocations = new VaultDataProvider.AllocationData[](3);

            assets[0] = address(usdt);
            allocations[0] = IVaultDataProvider.AllocationData({
                slope0: 0,
                slope1: 0,
                mintKinkRatio: 0,
                burnKinkRatio: 0,
                optimalRatio: 0
            });

            assets[1] = address(usdc);
            allocations[1] = IVaultDataProvider.AllocationData({
                slope0: 0,
                slope1: 0,
                mintKinkRatio: 0,
                burnKinkRatio: 0,
                optimalRatio: 0
            });

            assets[2] = address(usdx);
            allocations[2] = IVaultDataProvider.AllocationData({
                slope0: 0,
                slope1: 0,
                mintKinkRatio: 0,
                burnKinkRatio: 0,
                optimalRatio: 0
            });

            cUSDVault = Vault(
                vaultDataProvider.createVault(
                    address(cUSD),
                    IVaultDataProvider.VaultData({assets: assets, redeemFee: 0, paused: false}),
                    allocations
                )
            );

            vm.stopPrank();
        }

        // set the new vault oracle adapters
        {
            vm.startPrank(user_price_oracle_admin);

            // Set CapTokenAdapter as price source for cUSD
            priceOracle.setOracleData(
                address(cUSD),
                PriceOracle.OracleData({
                    adapter: address(capTokenAdapter),
                    payload: abi.encodeWithSelector(CapTokenAdapter.price.selector, address(addressProvider), address(cUSD))
                })
            );

            // Set StakedCapAdapter as price source for scUSD
            priceOracle.setOracleData(
                address(scUSD),
                PriceOracle.OracleData({
                    adapter: address(stakedCapAdapter),
                    payload: abi.encodeWithSelector(
                        StakedCapAdapter.price.selector, address(addressProvider), address(scUSD)
                    )
                })
            );

            vm.stopPrank();
        }

        // allow agents to borrow any assets
        {
            vm.startPrank(user_lender_admin);

            lender.addAsset(address(usdc), address(cUSDVault), 1e18);
            lender.addAsset(address(usdt), address(cUSDVault), 1e18);
            lender.addAsset(address(usdx), address(cUSDVault), 1e18);

            vm.stopPrank();
        }

        // make the agent covered
        {
            vm.startPrank(user_lender_admin);

            collateral.setCoverage(user_agent, 100000e18);
            collateral.setLtv(user_agent, 1e18);

            vm.stopPrank();
        }

        // bypass error on first deposit by having something in the vault
        {
            vm.startPrank(address(minter));

            usdt.mint(address(minter), 1000e18);
            usdc.mint(address(minter), 1000e18);
            usdx.mint(address(minter), 1000e18);
            usdt.approve(address(cUSDVault), 1000e18);
            usdc.approve(address(cUSDVault), 1000e18);
            usdx.approve(address(cUSDVault), 1000e18);
            cUSDVault.deposit(address(usdt), 1000e18);
            cUSDVault.deposit(address(usdc), 1000e18);
            cUSDVault.deposit(address(usdx), 1000e18);
            cUSD.mint(address(minter), 3000e18);

            vm.stopPrank();
        }
    }

    function testEmpty() public {
        // empty test to know how much gas is used by the setup() function
    }

    function testMintWithUSDT() public {
        vm.startPrank(user_stablecoin_minter);

        uint256 vaultBalanceBefore = usdt.balanceOf(address(cUSDVault));

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
        assertEq(usdt.balanceOf(address(cUSDVault)), vaultBalanceBefore + amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testMintWithDifferentPrices() public {
        vm.startPrank(user_stablecoin_minter);

        uint256 vaultBalanceBefore = usdt.balanceOf(address(cUSDVault));

        // Set USDT price to 1.02 USD
        usdtChainlinkPriceFeed.setLatestAnswer(102e8);

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
        assertEq(usdt.balanceOf(address(cUSDVault)), vaultBalanceBefore + amountIn, "Vault should have received USDT");

        vm.stopPrank();
    }

    function testMintAndBurn() public {
        vm.startPrank(user_stablecoin_minter);

        // Initial balances
        uint256 initialUsdtBalance = usdt.balanceOf(user_stablecoin_minter);
        uint256 initialVaultBalance = usdt.balanceOf(address(cUSDVault));

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
        assertEq(usdt.balanceOf(address(cUSDVault)), initialVaultBalance + amountIn, "Vault should have received USDT");

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

    function testMintStakeUnstakeBurn() public {
        vm.startPrank(user_stablecoin_minter);

        // Initial balances
        uint256 initialUsdtBalance = usdt.balanceOf(user_stablecoin_minter);
        uint256 initialVaultBalance = usdt.balanceOf(address(cUSDVault));

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
        assertEq(usdt.balanceOf(address(cUSDVault)), initialVaultBalance + amountIn, "Vault should have received USDT");

        // Now stake the cUSD tokens
        cUSD.approve(address(scUSD), mintedAmount);
        scUSD.deposit(mintedAmount, user_stablecoin_minter);

        uint256 stakedAmount = scUSD.balanceOf(user_stablecoin_minter);
        assertGt(stakedAmount, 0, "Should have staked cUSD tokens");

        // Now unstake the cUSD tokens
        scUSD.withdraw(stakedAmount, user_stablecoin_minter, user_stablecoin_minter);

        uint256 unstakedAmount = cUSD.balanceOf(user_stablecoin_minter);
        assertGt(unstakedAmount, 0, "Should have unstaked cUSD tokens");
        assertEq(scUSD.balanceOf(user_stablecoin_minter), 0, "Should have burned all staked cUSD tokens");

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

    function testAgentBorrowRepay() public {
        vm.startPrank(user_agent);

        address borrowAsset = address(usdc);
        uint256 borrowAmount = 1e18; // mock usdc has 18 decimals
        address receiver = user_agent;

        uint256 vaultBalanceBefore = usdc.balanceOf(address(cUSDVault));

        lender.borrow(borrowAsset, borrowAmount, receiver);
        assertEq(usdc.balanceOf(receiver), borrowAmount);

        //simulate yield
        usdc.mint(user_agent, 1000e18);

        // repay the debt
        uint256 interest = 10;
        usdc.approve(address(lender), borrowAmount + interest);
        lender.repay(borrowAsset, borrowAmount, user_agent);
        assertGe(usdc.balanceOf(address(cUSDVault)), vaultBalanceBefore);

        vm.stopPrank();
    }

    function testLiquidation() public {
        address borrowAsset = address(usdc);
        uint256 borrowAmount = 1e18; // mock usdc has 18 decimals
        address receiver = user_agent;

        // borrow some assets
        {
            vm.startPrank(user_agent);
            lender.borrow(borrowAsset, borrowAmount, receiver);
            assertEq(usdc.balanceOf(receiver), borrowAmount);
            vm.stopPrank();
        }

        // simulate a price drop
        {
            vm.startPrank(user_price_oracle_admin);
            usdtChainlinkPriceFeed.setLatestAnswer(90e8);
            usdcChainlinkPriceFeed.setLatestAnswer(90e8);
            usdxChainlinkPriceFeed.setLatestAnswer(90e8);
            vm.stopPrank();
        }

        // anyone can liquidate the debt
        {
            vm.startPrank(user_liquidator);
            // approve repay amount for liquidation
            usdc.approve(address(lender), borrowAmount);
            uint256 liquidatedAmount = lender.liquidate(user_agent, borrowAsset, borrowAmount);
            assertEq(liquidatedAmount, 100000e18);
            vm.stopPrank();
        }

        vm.stopPrank();
    }

    function testPriceOracle() public view {
        uint256 usdtPrice = IPriceOracle(address(priceOracle)).getPrice(address(usdt));
        assertEq(usdtPrice, 1e8, "USDT price should be $1");
    }

    function testRateOracle() public view {
        uint256 usdtRate = IRateOracle(address(rateOracle)).marketRate(address(usdt));
        assertEq(usdtRate, 1e17, "USDT borrow rate should be 10%, 1e18 being 100%");
    }

    function testCapAdapters() public view {
        uint256 cUSDPrice = IPriceOracle(address(priceOracle)).getPrice(address(cUSD));
        uint256 scUSDPrice = IPriceOracle(address(priceOracle)).getPrice(address(scUSD));
        assertApproxEqAbs(cUSDPrice, 1e8, 10, "cUSD price should be $1");
        assertApproxEqAbs(scUSDPrice, 1e8, 10, "scUSD price should be $1");
    }
}
