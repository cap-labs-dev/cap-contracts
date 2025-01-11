// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAddressProvider } from "../../contracts/interfaces/IAddressProvider.sol";
import { IPriceOracle } from "../../contracts/interfaces/IPriceOracle.sol";
import { IRateOracle } from "../../contracts/interfaces/IRateOracle.sol";
import { IStakedCap } from "../../contracts/interfaces/IStakedCap.sol";
import { IVaultDataProvider } from "../../contracts/interfaces/IVaultDataProvider.sol";
import { Lender } from "../../contracts/lendingPool/lender/Lender.sol";
import { InterestDebtToken } from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";
import { Minter } from "../../contracts/minter/Minter.sol";
import { PriceOracle } from "../../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../../contracts/oracle/RateOracle.sol";
import { AaveAdapter } from "../../contracts/oracle/libraries/AaveAdapter.sol";
import { CapTokenAdapter } from "../../contracts/oracle/libraries/CapTokenAdapter.sol";
import { ChainlinkAdapter } from "../../contracts/oracle/libraries/ChainlinkAdapter.sol";
import { StakedCapAdapter } from "../../contracts/oracle/libraries/StakedCapAdapter.sol";
import { AccessControl } from "../../contracts/registry/AccessControl.sol";
import { AddressProvider } from "../../contracts/registry/AddressProvider.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { Vault } from "../../contracts/vault/Vault.sol";
import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockCollateral } from "../mocks/MockCollateral.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract GasOptTest is Test {
    // external contract mocks
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

    // cap implementations
    AccessControl public accessControlProviderImplementation;
    AddressProvider public addressProviderImplementation;
    Minter public minterImplementation;
    Lender public lenderImplementation;
    CapToken public capTokenImplementation;
    Vault public vaultImplementation;
    StakedCap public stakedCapImplementation;
    PrincipalDebtToken public principalDebtTokenImplementation;
    InterestDebtToken public interestDebtTokenImplementation;
    RestakerDebtToken public restakerDebtTokenImplementation;
    PriceOracle public priceOracleImplementation;
    RateOracle public rateOracleImplementation;

    // cap instances
    AccessControl public accessControlProvider;
    AddressProvider public addressProvider;
    Minter public minter;
    Lender public lender;
    CapToken public cUSD;
    Vault public cUSDVault;
    StakedCap public scUSD;
    PriceOracle public priceOracle;
    RateOracle public rateOracle;
    address public aaveAdapter;
    address public chainlinkAdapter;
    address public capTokenAdapter;
    address public stakedCapAdapter;
    PrincipalDebtToken public usdtPrincipalDebtToken;
    PrincipalDebtToken public usdcPrincipalDebtToken;
    PrincipalDebtToken public usdxPrincipalDebtToken;
    RestakerDebtToken public usdtRestakerDebtToken;
    RestakerDebtToken public usdcRestakerDebtToken;
    RestakerDebtToken public usdxRestakerDebtToken;
    InterestDebtToken public usdtInterestDebtToken;
    InterestDebtToken public usdcInterestDebtToken;
    InterestDebtToken public usdxInterestDebtToken;

    address public user_deployer;
    address public user_agent;
    address public user_stablecoin_minter;
    address public user_liquidator;

    address public user_access_control_admin;
    address public user_address_provider_admin;
    address public user_interest_receiver;
    address public user_vault_keeper;
    address public user_price_oracle_admin;
    address public user_rate_oracle_admin;
    address public user_vault_config_admin;
    address public user_vaults_admin;
    address public user_lender_admin;

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }

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
            user_interest_receiver = makeAddr("interest_receiver");
            user_vault_keeper = makeAddr("vault_keeper");
            user_price_oracle_admin = makeAddr("user_price_oracle_admin");
            user_rate_oracle_admin = makeAddr("user_rate_oracle_admin");
            user_vault_config_admin = makeAddr("user_vault_config_admin");
            user_lender_admin = makeAddr("user_lender_admin");
            user_vaults_admin = makeAddr("user_vaults_admin");
            // Give gas to all users
            vm.deal(user_deployer, 100 ether);
            vm.deal(user_agent, 100 ether);
            vm.deal(user_stablecoin_minter, 100 ether);
            vm.deal(user_liquidator, 100 ether);
            vm.deal(user_access_control_admin, 100 ether);
            vm.deal(user_address_provider_admin, 100 ether);
            vm.deal(user_interest_receiver, 100 ether);
            vm.deal(user_vault_keeper, 100 ether);
            vm.deal(user_price_oracle_admin, 100 ether);
            vm.deal(user_rate_oracle_admin, 100 ether);
            vm.deal(user_lender_admin, 100 ether);
            vm.deal(user_vault_config_admin, 100 ether);
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

        // deploy implementations
        {
            vm.startPrank(user_deployer);

            accessControlProviderImplementation = new AccessControl();
            addressProviderImplementation = new AddressProvider();
            minterImplementation = new Minter();
            lenderImplementation = new Lender();
            capTokenImplementation = new CapToken();
            vaultImplementation = new Vault();
            stakedCapImplementation = new StakedCap();
            principalDebtTokenImplementation = new PrincipalDebtToken();
            interestDebtTokenImplementation = new InterestDebtToken();
            restakerDebtTokenImplementation = new RestakerDebtToken();

            priceOracleImplementation = new PriceOracle();
            rateOracleImplementation = new RateOracle();

            // grab libraries addresses
            aaveAdapter = address(AaveAdapter);
            chainlinkAdapter = address(ChainlinkAdapter);
            capTokenAdapter = address(CapTokenAdapter);
            stakedCapAdapter = address(StakedCapAdapter);

            vm.stopPrank();
        }

        // Deploy external contract mocks
        {
            vm.startPrank(user_deployer);

            // Deploy mock data providers
            usdtAaveDataProvider = new MockAaveDataProvider();
            usdcAaveDataProvider = new MockAaveDataProvider();
            usdxAaveDataProvider = new MockAaveDataProvider();
            usdtChainlinkPriceFeed = new MockChainlinkPriceFeed();
            usdcChainlinkPriceFeed = new MockChainlinkPriceFeed();
            usdxChainlinkPriceFeed = new MockChainlinkPriceFeed();
            collateral = new MockCollateral();

            vm.stopPrank();
        }

        // deployment infra instances
        {
            vm.startPrank(user_deployer);

            // deploy all infra instances
            accessControlProvider = AccessControl(_proxy(address(accessControlProviderImplementation)));
            addressProvider = AddressProvider(_proxy(address(addressProviderImplementation)));
            minter = Minter(_proxy(address(minterImplementation)));
            lender = Lender(_proxy(address(lenderImplementation)));
            priceOracle = PriceOracle(_proxy(address(priceOracleImplementation)));
            rateOracle = RateOracle(_proxy(address(rateOracleImplementation)));

            // initialize contracts
            accessControlProvider.initialize(user_access_control_admin);
            addressProvider.initialize(
                address(accessControlProvider),
                address(lender),
                address(collateral),
                address(priceOracle),
                address(rateOracle),
                address(minter)
            );
            minter.initialize(address(addressProvider), address(accessControlProvider));
            lender.initialize(address(addressProvider), address(accessControlProvider));
            priceOracle.initialize(address(accessControlProvider));
            rateOracle.initialize(address(accessControlProvider));

            vm.stopPrank();
        }

        // Setup access control roles
        {
            vm.startPrank(user_access_control_admin);

            accessControlProvider.grantAccess(
                AddressProvider.setVault.selector, address(addressProvider), user_address_provider_admin
            );
            accessControlProvider.grantAccess(
                AddressProvider.setInterestReceiver.selector, address(addressProvider), user_address_provider_admin
            );
            accessControlProvider.grantAccess(
                AddressProvider.setRestakerInterestReceiver.selector,
                address(addressProvider),
                user_address_provider_admin
            );
            accessControlProvider.grantAccess(
                PriceOracle.setOracleData.selector, address(priceOracle), user_price_oracle_admin
            );
            accessControlProvider.grantAccess(
                PriceOracle.setBackupOracleData.selector, address(priceOracle), user_price_oracle_admin
            );

            accessControlProvider.grantAccess(
                RateOracle.setOracleData.selector, address(rateOracle), user_rate_oracle_admin
            );
            accessControlProvider.grantAccess(
                RateOracle.setBenchmarkRate.selector, address(rateOracle), user_rate_oracle_admin
            );
            accessControlProvider.grantAccess(
                RateOracle.setRestakerRate.selector, address(rateOracle), user_rate_oracle_admin
            );

            accessControlProvider.grantAccess(Lender.addAsset.selector, address(lender), user_lender_admin);
            accessControlProvider.grantAccess(Lender.removeAsset.selector, address(lender), user_lender_admin);
            accessControlProvider.grantAccess(Lender.pauseAsset.selector, address(lender), user_lender_admin);

            vm.stopPrank();
        }

        // Set initial oracles data
        {
            vm.startPrank(user_deployer);

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

            address[] memory roleMembers = accessControlProvider.getRoleMembers(
                accessControlProvider.role(priceOracle.setOracleData.selector, address(priceOracle))
            );
            for (uint256 i = 0; i < roleMembers.length; i++) {
                console.log("roleMembers", roleMembers[i]);
            }

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

        {
            vm.startPrank(user_deployer);

            cUSD = CapToken(_proxy(address(capTokenImplementation)));
            scUSD = StakedCap(_proxy(address(stakedCapImplementation)));
            cUSDVault = Vault(_proxy(address(vaultImplementation)));

            cUSD.initialize("Capped USD", "cUSD", address(accessControlProvider));
            scUSD.initialize(address(addressProvider), address(cUSD));
            cUSDVault.initialize(address(accessControlProvider));

            vm.stopPrank();
        }

        // configure access control
        {
            vm.startPrank(user_access_control_admin);

            accessControlProvider.grantAccess(CapToken.mint.selector, address(cUSD), address(minter));
            accessControlProvider.grantAccess(CapToken.burn.selector, address(cUSD), address(minter));
            accessControlProvider.grantAccess(Vault.deposit.selector, address(cUSDVault), address(minter));
            accessControlProvider.grantAccess(Vault.withdraw.selector, address(cUSDVault), address(minter));

            accessControlProvider.grantAccess(
                Vault.addAsset.selector, address(cUSDVault), address(user_vault_config_admin)
            );
            accessControlProvider.grantAccess(
                Minter.setFeeData.selector, address(minter), address(user_vault_config_admin)
            );
            accessControlProvider.grantAccess(
                Minter.swapExactTokenForTokens.selector, address(minter), address(user_vault_config_admin)
            );
            accessControlProvider.grantAccess(
                AddressProvider.setVault.selector, address(addressProvider), address(user_vault_config_admin)
            );

            vm.stopPrank();
        }

        // Setup cUSD
        {
            vm.startPrank(user_vault_config_admin);

            addressProvider.setVault(address(cUSD), address(cUSDVault));

            cUSDVault.addAsset(address(usdt));
            cUSDVault.addAsset(address(usdc));
            cUSDVault.addAsset(address(usdx));

            minter.setFeeData(
                address(cUSDVault),
                address(usdt),
                Minter.FeeData({ slope0: 0, slope1: 0, mintKinkRatio: 0, burnKinkRatio: 0, optimalRatio: 0 })
            );
            minter.setFeeData(
                address(cUSDVault),
                address(usdc),
                Minter.FeeData({ slope0: 0, slope1: 0, mintKinkRatio: 0, burnKinkRatio: 0, optimalRatio: 0 })
            );
            minter.setFeeData(
                address(cUSDVault),
                address(usdx),
                Minter.FeeData({ slope0: 0, slope1: 0, mintKinkRatio: 0, burnKinkRatio: 0, optimalRatio: 0 })
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

        // deploy vault debt tokens
        {
            vm.startPrank(user_deployer);

            usdcPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));
            usdxPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));
            usdtPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));

            usdtRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));
            usdcRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));
            usdxRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));

            usdcInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));
            usdtInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));
            usdxInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));

            usdcPrincipalDebtToken.initialize(address(accessControlProvider), address(usdc));
            usdtPrincipalDebtToken.initialize(address(accessControlProvider), address(usdt));
            usdxPrincipalDebtToken.initialize(address(accessControlProvider), address(usdx));

            usdcRestakerDebtToken.initialize(address(addressProvider), address(usdcPrincipalDebtToken), address(usdc));
            usdtRestakerDebtToken.initialize(address(addressProvider), address(usdtPrincipalDebtToken), address(usdt));
            usdxRestakerDebtToken.initialize(address(addressProvider), address(usdxPrincipalDebtToken), address(usdx));

            usdcInterestDebtToken.initialize(address(addressProvider), address(usdcPrincipalDebtToken), address(usdc));
            usdtInterestDebtToken.initialize(address(addressProvider), address(usdtPrincipalDebtToken), address(usdt));
            usdxInterestDebtToken.initialize(address(addressProvider), address(usdxPrincipalDebtToken), address(usdx));

            vm.stopPrank();
        }

        // configure lender access control
        {
            vm.startPrank(user_access_control_admin);

            accessControlProvider.grantAccess(Lender.addAsset.selector, address(lender), address(user_lender_admin));
            accessControlProvider.grantAccess(Lender.removeAsset.selector, address(lender), address(user_lender_admin));

            accessControlProvider.grantAccess(Lender.borrow.selector, address(lender), address(user_lender_admin));
            accessControlProvider.grantAccess(Lender.repay.selector, address(lender), address(user_lender_admin));

            accessControlProvider.grantAccess(Lender.liquidate.selector, address(lender), address(user_lender_admin));
            accessControlProvider.grantAccess(Lender.pauseAsset.selector, address(lender), address(user_lender_admin));

            accessControlProvider.grantAccess(Vault.borrow.selector, address(cUSDVault), address(lender));
            accessControlProvider.grantAccess(Vault.repay.selector, address(cUSDVault), address(lender));

            bytes4[] memory selectors = new bytes4[](4);
            selectors[0] = PrincipalDebtToken.mint.selector;
            selectors[1] = PrincipalDebtToken.burn.selector;
            selectors[2] = RestakerDebtToken.burn.selector;
            selectors[3] = InterestDebtToken.burn.selector;

            address[] memory addresses = new address[](3);
            addresses[0] = address(usdcPrincipalDebtToken);
            addresses[1] = address(usdtPrincipalDebtToken);
            addresses[2] = address(usdxPrincipalDebtToken);

            for (uint256 i = 0; i < selectors.length; i++) {
                for (uint256 j = 0; j < addresses.length; j++) {
                    accessControlProvider.grantAccess(selectors[i], addresses[j], address(lender));
                }
            }

            vm.stopPrank();
        }

        // configure lender
        {
            vm.startPrank(user_address_provider_admin);

            addressProvider.setInterestReceiver(address(usdc), address(user_interest_receiver));
            addressProvider.setInterestReceiver(address(usdt), address(user_interest_receiver));
            addressProvider.setInterestReceiver(address(usdx), address(user_interest_receiver));

            addressProvider.setRestakerInterestReceiver(address(user_agent), address(user_interest_receiver));
            addressProvider.setRestakerInterestReceiver(address(user_agent), address(user_interest_receiver));
            addressProvider.setRestakerInterestReceiver(address(user_agent), address(user_interest_receiver));

            vm.stopPrank();
        }

        // allow agents to borrow any assets
        {
            vm.startPrank(user_lender_admin);

            lender.addAsset(
                address(usdc),
                address(cUSDVault),
                address(usdcPrincipalDebtToken),
                address(usdcRestakerDebtToken),
                address(usdcInterestDebtToken),
                1e18
            );

            lender.addAsset(
                address(usdt),
                address(cUSDVault),
                address(usdtPrincipalDebtToken),
                address(usdtRestakerDebtToken),
                address(usdtInterestDebtToken),
                1e18
            );

            lender.addAsset(
                address(usdx),
                address(cUSDVault),
                address(usdxPrincipalDebtToken),
                address(usdxRestakerDebtToken),
                address(usdxInterestDebtToken),
                1e18
            );

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
