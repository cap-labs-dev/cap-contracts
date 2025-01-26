// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../contracts/access/AccessControl.sol";
import { Lender } from "../contracts/lendingPool/Lender.sol";

import { InterestDebtToken } from "../contracts/lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../contracts/lendingPool/tokens/RestakerDebtToken.sol";

import { IOracle } from "../contracts/interfaces/IOracle.sol";
import { DataTypes } from "../contracts/lendingPool/libraries/types/DataTypes.sol";
import { Oracle } from "../contracts/oracle/Oracle.sol";
import { PriceOracle } from "../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../contracts/oracle/RateOracle.sol";
import { AaveAdapter } from "../contracts/oracle/libraries/AaveAdapter.sol";
import { CapTokenAdapter } from "../contracts/oracle/libraries/CapTokenAdapter.sol";
import { ChainlinkAdapter } from "../contracts/oracle/libraries/ChainlinkAdapter.sol";
import { StakedCapAdapter } from "../contracts/oracle/libraries/StakedCapAdapter.sol";
import { CapToken } from "../contracts/token/CapToken.sol";
import { StakedCap } from "../contracts/token/StakedCap.sol";
import { VaultUpgradeable } from "../contracts/vault/VaultUpgradeable.sol";
import { MockAaveDataProvider } from "../test/mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../test/mocks/MockChainlinkPriceFeed.sol";
import { MockDelegation } from "../test/mocks/MockDelegation.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";

import { ProxyUtils } from "./util/ProxyUtils.sol";
import { WalletUtils } from "./util/WalletUtils.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployTestnetVault is Script, WalletUtils, ProxyUtils {
    // external contract mocks
    MockAaveDataProvider public usdtAaveDataProvider;
    MockAaveDataProvider public usdcAaveDataProvider;
    MockAaveDataProvider public usdxAaveDataProvider;
    MockChainlinkPriceFeed public usdtChainlinkPriceFeed;
    MockChainlinkPriceFeed public usdcChainlinkPriceFeed;
    MockChainlinkPriceFeed public usdxChainlinkPriceFeed;
    MockDelegation public delegation;
    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public usdx;

    // cap implementations
    AccessControl public accessControlImplementation;
    Lender public lenderImplementation;
    CapToken public capTokenImplementation;
    StakedCap public stakedCapImplementation;
    PrincipalDebtToken public principalDebtTokenImplementation;
    InterestDebtToken public interestDebtTokenImplementation;
    RestakerDebtToken public restakerDebtTokenImplementation;
    Oracle public oracleImplementation;

    // cap instances
    AccessControl public accessControl;
    Lender public lender;
    CapToken public cUSD;
    StakedCap public scUSD;
    Oracle public oracle;
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

    function log_addresses() private view {
        // external contract mocks
        console.log("usdtAaveDataProvider", address(usdtAaveDataProvider));
        console.log("usdcAaveDataProvider", address(usdcAaveDataProvider));
        console.log("usdxAaveDataProvider", address(usdxAaveDataProvider));
        console.log("usdtChainlinkPriceFeed", address(usdtChainlinkPriceFeed));
        console.log("usdcChainlinkPriceFeed", address(usdcChainlinkPriceFeed));
        console.log("usdxChainlinkPriceFeed", address(usdxChainlinkPriceFeed));
        console.log("delegation", address(delegation));
        console.log("usdt", address(usdt));
        console.log("usdc", address(usdc));
        console.log("usdx", address(usdx));

        // cap implementations
        console.log("accessControlImplementation", address(accessControlImplementation));
        console.log("lenderImplementation", address(lenderImplementation));
        console.log("capTokenImplementation", address(capTokenImplementation));
        console.log("stakedCapImplementation", address(stakedCapImplementation));
        console.log("principalDebtTokenImplementation", address(principalDebtTokenImplementation));
        console.log("interestDebtTokenImplementation", address(interestDebtTokenImplementation));
        console.log("restakerDebtTokenImplementation", address(restakerDebtTokenImplementation));
        console.log("oracleImplementation", address(oracleImplementation));

        // cap instances
        console.log("accessControl", address(accessControl));
        console.log("lender", address(lender));
        console.log("cUSD", address(cUSD));
        console.log("scUSD", address(scUSD));
        console.log("oracle", address(oracle));
        console.log("aaveAdapter", address(aaveAdapter));
        console.log("chainlinkAdapter", address(chainlinkAdapter));
        console.log("capTokenAdapter", address(capTokenAdapter));
        console.log("stakedCapAdapter", address(stakedCapAdapter));
        console.log("usdtPrincipalDebtToken", address(usdtPrincipalDebtToken));
        console.log("usdcPrincipalDebtToken", address(usdcPrincipalDebtToken));
        console.log("usdxPrincipalDebtToken", address(usdxPrincipalDebtToken));
        console.log("usdtRestakerDebtToken", address(usdtRestakerDebtToken));
        console.log("usdcRestakerDebtToken", address(usdcRestakerDebtToken));
        console.log("usdxRestakerDebtToken", address(usdxRestakerDebtToken));
        console.log("usdtInterestDebtToken", address(usdtInterestDebtToken));
        console.log("usdcInterestDebtToken", address(usdcInterestDebtToken));
        console.log("usdxInterestDebtToken", address(usdxInterestDebtToken));
    }

    function run() external {
        vm.startBroadcast();

        // Get the broadcast address (deployer's address)
        address user_agent = getWalletAddress();
        address user_access_control_admin = getWalletAddress();
        address user_oracle_admin = getWalletAddress();
        address user_rate_oracle_admin = getWalletAddress();
        address user_lender_admin = getWalletAddress();
        address user_stablecoin_minter = getWalletAddress();
        address user_liquidator = getWalletAddress();
        address user_interest_receiver = getWalletAddress();

        // Deploy mock tokens
        {
            usdt = new MockERC20("USDT", "USDT", 6);
            usdc = new MockERC20("USDC", "USDC", 6);
            usdx = new MockERC20("USDx", "USDx", 18);

            // Mint tokens to minter
            usdt.mint(user_stablecoin_minter, 1_000_000e6);
            usdc.mint(user_stablecoin_minter, 1_000_000e6);
            usdx.mint(user_stablecoin_minter, 1_000_000e18);

            // mint some tokens to the liquidator for repayments
            usdt.mint(user_liquidator, 1000e6);
            usdc.mint(user_liquidator, 1000e6);
            usdx.mint(user_liquidator, 1000e18);
        }

        // deploy implementations and contracts
        {
            accessControlImplementation = new AccessControl();
            lenderImplementation = new Lender();
            capTokenImplementation = new CapToken();
            stakedCapImplementation = new StakedCap();
            oracleImplementation = new Oracle();
            principalDebtTokenImplementation = new PrincipalDebtToken();
            interestDebtTokenImplementation = new InterestDebtToken();
            restakerDebtTokenImplementation = new RestakerDebtToken();

            // grab libraries addresses
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
            delegation = new MockDelegation();

            // deploy proxy contracts
            accessControl = AccessControl(_proxy(address(accessControlImplementation)));
            lender = Lender(_proxy(address(lenderImplementation)));
            oracle = Oracle(_proxy(address(oracleImplementation)));

            // init infra instances
            accessControl.initialize(user_access_control_admin);
            uint256 targetHealth = 1e18;
            uint256 grace = 1 hours;
            uint256 expiry = block.timestamp + 1 hours;
            uint256 bonusCap = 1e18;
            lender.initialize(
                address(accessControl), address(delegation), address(oracle), targetHealth, grace, expiry, bonusCap
            );
            oracle.initialize(address(accessControl));

            // deploy and init cap instances
            cUSD = CapToken(_proxy(address(capTokenImplementation)));
            scUSD = StakedCap(_proxy(address(stakedCapImplementation)));

            address[] memory assets = new address[](3);
            assets[0] = address(usdt);
            assets[1] = address(usdc);
            assets[2] = address(usdx);

            cUSD.initialize("Capped USD", "cUSD", address(accessControl), address(oracle), assets);
            scUSD.initialize(address(accessControl), address(cUSD), 6 hours);

            // deploy and init debt tokens
            usdcPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));
            usdxPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));
            usdtPrincipalDebtToken = PrincipalDebtToken(_proxy(address(principalDebtTokenImplementation)));

            usdtRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));
            usdcRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));
            usdxRestakerDebtToken = RestakerDebtToken(_proxy(address(restakerDebtTokenImplementation)));

            usdcInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));
            usdtInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));
            usdxInterestDebtToken = InterestDebtToken(_proxy(address(interestDebtTokenImplementation)));

            usdcPrincipalDebtToken.initialize(address(accessControl), address(usdc));
            usdtPrincipalDebtToken.initialize(address(accessControl), address(usdt));
            usdxPrincipalDebtToken.initialize(address(accessControl), address(usdx));

            usdcRestakerDebtToken.initialize(
                address(accessControl), address(oracle), address(usdcPrincipalDebtToken), address(usdc)
            );
            usdtRestakerDebtToken.initialize(
                address(accessControl), address(oracle), address(usdtPrincipalDebtToken), address(usdt)
            );
            usdxRestakerDebtToken.initialize(
                address(accessControl), address(oracle), address(usdxPrincipalDebtToken), address(usdx)
            );

            usdcInterestDebtToken.initialize(
                address(accessControl), address(oracle), address(usdcPrincipalDebtToken), address(usdc)
            );
            usdtInterestDebtToken.initialize(
                address(accessControl), address(oracle), address(usdtPrincipalDebtToken), address(usdt)
            );
            usdxInterestDebtToken.initialize(
                address(accessControl), address(oracle), address(usdxPrincipalDebtToken), address(usdx)
            );
        }

        // Setup access control roles
        {
            accessControl.grantAccess(IOracle.setPriceOracleData.selector, address(oracle), user_oracle_admin);
            accessControl.grantAccess(IOracle.setPriceBackupOracleData.selector, address(oracle), user_oracle_admin);
            accessControl.grantAccess(IOracle.setRateOracleData.selector, address(oracle), user_oracle_admin);

            accessControl.grantAccess(IOracle.setPriceOracleData.selector, address(oracle), user_rate_oracle_admin);
            accessControl.grantAccess(IOracle.setBenchmarkRate.selector, address(oracle), user_rate_oracle_admin);
            accessControl.grantAccess(IOracle.setRestakerRate.selector, address(oracle), user_rate_oracle_admin);

            accessControl.grantAccess(Lender.addAsset.selector, address(lender), user_lender_admin);
            accessControl.grantAccess(Lender.removeAsset.selector, address(lender), user_lender_admin);
            accessControl.grantAccess(Lender.pauseAsset.selector, address(lender), user_lender_admin);

            accessControl.grantAccess(VaultUpgradeable.borrow.selector, address(cUSD), address(lender));
            accessControl.grantAccess(VaultUpgradeable.repay.selector, address(cUSD), address(lender));
        }

        // Setup oracle for assets (usdt, usdc, usdx)
        {
            // assets price oracle data
            usdtChainlinkPriceFeed.setDecimals(8);
            usdcChainlinkPriceFeed.setDecimals(8);
            usdxChainlinkPriceFeed.setDecimals(8);
            usdtChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals
            usdcChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals
            usdxChainlinkPriceFeed.setLatestAnswer(1e8); // $1.00 with 8 decimals

            // assets rate oracle data
            usdtAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%
            usdcAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%
            usdxAaveDataProvider.setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%

            // cUSD price oracle data
            IOracle.OracleData memory usdtOracleData = IOracle.OracleData({
                adapter: address(chainlinkAdapter),
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdtChainlinkPriceFeed))
            });
            IOracle.OracleData memory usdcOracleData = IOracle.OracleData({
                adapter: address(chainlinkAdapter),
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdcChainlinkPriceFeed))
            });
            IOracle.OracleData memory usdxOracleData = IOracle.OracleData({
                adapter: address(chainlinkAdapter),
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(usdxChainlinkPriceFeed))
            });
            oracle.setPriceOracleData(address(usdt), usdtOracleData);
            oracle.setPriceOracleData(address(usdc), usdcOracleData);
            oracle.setPriceOracleData(address(usdx), usdxOracleData);
            oracle.setPriceBackupOracleData(address(usdt), usdtOracleData);
            oracle.setPriceBackupOracleData(address(usdc), usdcOracleData);
            oracle.setPriceBackupOracleData(address(usdx), usdxOracleData);

            // cUSD rate oracle data
            IOracle.OracleData memory usdtRateData = IOracle.OracleData({
                adapter: address(aaveAdapter),
                payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdtAaveDataProvider), address(usdt))
            });
            IOracle.OracleData memory usdcRateData = IOracle.OracleData({
                adapter: address(aaveAdapter),
                payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdcAaveDataProvider), address(usdc))
            });
            IOracle.OracleData memory usdxRateData = IOracle.OracleData({
                adapter: address(aaveAdapter),
                payload: abi.encodeWithSelector(AaveAdapter.rate.selector, address(usdxAaveDataProvider), address(usdx))
            });
            oracle.setRateOracleData(address(usdt), usdtRateData);
            oracle.setRateOracleData(address(usdc), usdcRateData);
            oracle.setRateOracleData(address(usdx), usdxRateData);

            // cUSD and scUSD price oracle data
            IOracle.OracleData memory cUSDOracleData = IOracle.OracleData({
                adapter: address(capTokenAdapter),
                payload: abi.encodeWithSelector(CapTokenAdapter.price.selector, address(cUSD))
            });
            IOracle.OracleData memory scUSDOracleData = IOracle.OracleData({
                adapter: address(stakedCapAdapter),
                payload: abi.encodeWithSelector(StakedCapAdapter.price.selector, address(scUSD))
            });
            oracle.setPriceOracleData(address(cUSD), cUSDOracleData);
            oracle.setPriceOracleData(address(scUSD), scUSDOracleData);
            oracle.setPriceBackupOracleData(address(cUSD), cUSDOracleData);
            oracle.setPriceBackupOracleData(address(scUSD), scUSDOracleData);
        }

        // configure lender access control
        {
            accessControl.grantAccess(Lender.addAsset.selector, address(lender), address(user_lender_admin));
            accessControl.grantAccess(Lender.removeAsset.selector, address(lender), address(user_lender_admin));

            accessControl.grantAccess(Lender.borrow.selector, address(lender), address(user_lender_admin));
            accessControl.grantAccess(Lender.repay.selector, address(lender), address(user_lender_admin));

            accessControl.grantAccess(Lender.liquidate.selector, address(lender), address(user_lender_admin));
            accessControl.grantAccess(Lender.pauseAsset.selector, address(lender), address(user_lender_admin));

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
                    accessControl.grantAccess(selectors[i], addresses[j], address(lender));
                }
            }
        }

        // allow agents to borrow any assets
        {
            lender.addAsset(
                DataTypes.AddAssetParams({
                    asset: address(usdc),
                    vault: address(cUSD),
                    principalDebtToken: address(usdcPrincipalDebtToken),
                    restakerDebtToken: address(usdcRestakerDebtToken),
                    interestDebtToken: address(usdcInterestDebtToken),
                    interestReceiver: address(user_interest_receiver),
                    decimals: 18,
                    bonusCap: 1e18
                })
            );

            lender.addAsset(
                DataTypes.AddAssetParams({
                    asset: address(usdt),
                    vault: address(cUSD),
                    principalDebtToken: address(usdtPrincipalDebtToken),
                    restakerDebtToken: address(usdtRestakerDebtToken),
                    interestDebtToken: address(usdtInterestDebtToken),
                    interestReceiver: address(user_interest_receiver),
                    decimals: 18,
                    bonusCap: 1e18
                })
            );

            lender.addAsset(
                DataTypes.AddAssetParams({
                    asset: address(usdx),
                    vault: address(cUSD),
                    principalDebtToken: address(usdxPrincipalDebtToken),
                    restakerDebtToken: address(usdxRestakerDebtToken),
                    interestDebtToken: address(usdxInterestDebtToken),
                    interestReceiver: address(user_interest_receiver),
                    decimals: 18,
                    bonusCap: 1e18
                })
            );

            lender.pauseAsset(address(usdc), false);
            lender.pauseAsset(address(usdt), false);
            lender.pauseAsset(address(usdx), false);
        }

        // make the agent covered
        {
            delegation.setCoverage(user_agent, 100000e18);
            delegation.setLtv(user_agent, 1e18);
        }

        // init the vault with some assets
        {
            usdc.approve(address(cUSD), 4000e18);
            cUSD.mint(address(usdc), 4000e6, 0, user_stablecoin_minter, block.timestamp + 1 hours);
            usdt.approve(address(cUSD), 4000e18);
            cUSD.mint(address(usdt), 4000e6, 0, user_stablecoin_minter, block.timestamp + 1 hours);
            usdx.approve(address(cUSD), 4000e18);
            cUSD.mint(address(usdx), 4000e18, 0, user_stablecoin_minter, block.timestamp + 1 hours);

            console.log("cUSD balance", cUSD.balanceOf(user_stablecoin_minter));
            cUSD.transfer(address(0xDead), cUSD.balanceOf(user_stablecoin_minter));
        }

        log_addresses();

        vm.stopBroadcast();
    }
}
