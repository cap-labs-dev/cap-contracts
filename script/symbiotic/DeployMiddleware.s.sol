// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LzUtils } from "../util/LzUtils.sol";

import { CapSymbioticNetworkMiddleware } from "../../contracts/collateral/symbiotic/CapSymbioticNetworkMiddleware.sol";
import { OperatorSpecificDecreaseHook } from "../../contracts/collateral/symbiotic/OperatorSpecificDecreaseHook.sol";

import { MockERC20 } from "../../test/mocks/MockERC20.sol";
import { SymbioticUtils } from "../util/SymbioticUtils.sol";
import { WalletUtils } from "../util/WalletUtils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IBurnerRouterFactory } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol";
import { IVaultConfigurator } from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";
import { IDelegatorHook } from "@symbioticfi/core/src/interfaces/delegator/IDelegatorHook.sol";

import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";

import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { IBaseSlasher } from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the lockboxes for the cap token and staked cap token
 */
contract DeployMiddleware is Script, WalletUtils, SymbioticUtils {
    address public constant CAP_NETWORK_ADDRESS = 0x58D347334A5E6bDE7279696abE59a11873294FA4;

    SymbioticConfig public symbioticConfig;
    CapSymbioticNetworkMiddleware public middlewareImplementation;

    MockERC20 public collateral;
    IBurnerRouter public burnerRouter;
    uint48 public burnerRouterDelay = 0;
    uint48 public vaultEpochDuration = 1 hours;
    IDelegatorHook public hook;
    CapSymbioticNetworkMiddleware public middleware;
    IVault public vault;
    INetworkRestakeDelegator public networkRestakeDelegator;
    ISlasher public immediateSlasher;
    IDefaultStakerRewards public defaultStakerRewards;

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }

    function run() public {
        // pull config
        collateral = MockERC20(0xbDb6B30d716b7a864e0E482C9D703057b46BF218); // mock USDC
        address admin = getWalletAddress();
        address capNetwork = getWalletAddress();
        symbioticConfig = getConfig();

        console.log("collateral", address(collateral));
        console.log("admin", admin);
        console.log("capNetwork", capNetwork);

        vm.startBroadcast();

        middlewareImplementation = new CapSymbioticNetworkMiddleware();
        middleware = CapSymbioticNetworkMiddleware(_proxy(address(middlewareImplementation)));

        console.log("middlewareImplementation", address(middlewareImplementation));
        console.log("middleware", address(middleware));

        // setup vault
        {
            // burner router setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#1-burner-router
            // https://docs.symbiotic.fi/guides/vault-deployment#network-specific-burners
            IBurnerRouter.NetworkReceiver[] memory networkReceivers = new IBurnerRouter.NetworkReceiver[](1);
            networkReceivers[0] = IBurnerRouter.NetworkReceiver({ network: capNetwork, receiver: address(middleware) });
            burnerRouter = IBurnerRouter(
                IBurnerRouterFactory(symbioticConfig.burnerRouterFactory).create(
                    IBurnerRouter.InitParams({
                        owner: admin, // address of the router’s owner
                        collateral: address(collateral), // address of the collateral - wstETH (MUST be the same as for the Vault to connect)
                        delay: burnerRouterDelay, // duration of the receivers’ update delay (= 21 days)
                        globalReceiver: 0x58D347334A5E6bDE7279696abE59a11873294FA4, // address of the pure burner corresponding to the collateral - wstETH_Burner (some collaterals are covered by us; see Deployments page)
                        networkReceivers: networkReceivers, // array with IBurnerRouter.NetworkReceiver elements meaning network-specific receivers
                        operatorNetworkReceivers: new IBurnerRouter.OperatorNetworkReceiver[](0) // array with IBurnerRouter.OperatorNetworkReceiver elements meaning network-specific receivers
                     })
                )
            );

            // hook setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#hook
            // https://docs.symbiotic.fi/modules/extensions/hooks/
            hook = new OperatorSpecificDecreaseHook();

            // vault setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#vault
            address[] memory networkLimitSetRoleHolders = new address[](2);
            networkLimitSetRoleHolders[0] = admin;
            networkLimitSetRoleHolders[1] = address(hook);

            address[] memory operatorNetworkSharesSetRoleHolders = new address[](2);
            operatorNetworkSharesSetRoleHolders[0] = admin;
            operatorNetworkSharesSetRoleHolders[1] = address(hook);

            (address _vault, address _networkRestakeDelegator, address _immediateSlasher) = IVaultConfigurator(
                symbioticConfig.vaultConfigurator
            ).create(
                IVaultConfigurator.InitParams({
                    version: 1, // Vault’s version (= common one)
                    owner: admin, // address of the Vault’s owner (can migrate the Vault to new versions in the future)
                    vaultParams: abi.encode(
                        IVault.InitParams({
                            collateral: address(collateral), // address of the collateral - wstETH
                            burner: address(burnerRouter), // address of the deployed burner router
                            epochDuration: vaultEpochDuration, // duration of the Vault epoch in seconds (= 7 days)
                            depositWhitelist: false, // if enable deposit whitelisting
                            isDepositLimit: false, // if enable deposit limit
                            depositLimit: 0, // deposit limit
                            defaultAdminRoleHolder: admin, // address of the Vault’s admin (can manage all roles)
                            depositWhitelistSetRoleHolder: admin, // address of the enabler/disabler of the deposit whitelisting
                            depositorWhitelistRoleHolder: admin, // address of the depositors whitelister
                            isDepositLimitSetRoleHolder: admin, // address of the enabler/disabler of the deposit limit
                            depositLimitSetRoleHolder: admin // address of the deposit limit setter
                         })
                    ),
                    delegatorIndex: 0, // Delegator’s type (= NetworkRestakeDelegator)
                    delegatorParams: abi.encode(
                        INetworkRestakeDelegator.InitParams({
                            baseParams: IBaseDelegator.BaseParams({
                                defaultAdminRoleHolder: admin, // address of the Delegator’s admin (can manage all roles)
                                hook: address(hook), // address of the hook (if not zero, receives onSlash() call on each slashing)
                                hookSetRoleHolder: admin // address of the hook setter
                             }),
                            networkLimitSetRoleHolders: networkLimitSetRoleHolders, // array of addresses of the network limit setters
                            operatorNetworkSharesSetRoleHolders: operatorNetworkSharesSetRoleHolders // array of addresses of the operator-network shares setters
                         })
                    ),
                    withSlasher: true, // if enable Slasher module
                    slasherIndex: 0, // Slasher’s type (0 = ImmediateSlasher, 1 = VetoSlasher)
                    slasherParams: abi.encode(
                        ISlasher.InitParams({
                            baseParams: IBaseSlasher.BaseParams({
                                isBurnerHook: true // if enable the `burner` to receive onSlash() call after each slashing (is needed for the burner router workflow)
                             })
                        })
                    )
                })
            );
            vault = IVault(_vault);
            networkRestakeDelegator = INetworkRestakeDelegator(_networkRestakeDelegator);
            immediateSlasher = ISlasher(_immediateSlasher);

            // default staker rewards setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#3-staker-rewards
            defaultStakerRewards = IDefaultStakerRewards(
                IDefaultStakerRewardsFactory(symbioticConfig.defaultStakerRewardsFactory).create(
                    IDefaultStakerRewards.InitParams({
                        vault: address(vault), // address of the deployed Vault
                        adminFee: 1000, // admin fee percent to get from all the rewards distributions (10% = 1_000 | 100% = 10_000)
                        defaultAdminRoleHolder: admin, // address of the main admin (can manage all roles)
                        adminFeeClaimRoleHolder: admin, // address of the admin fee claimer
                        adminFeeSetRoleHolder: admin // address of the admin fee setter
                     })
                )
            );

            console.log("burnerRouter", address(burnerRouter));
            console.log("hook", address(hook));
            console.log("vault", address(vault));
            console.log("networkRestakeDelegator", address(networkRestakeDelegator));
            console.log("immediateSlasher", address(immediateSlasher));
            console.log("defaultStakerRewards", address(defaultStakerRewards));
        }

        // setup network
        {
            middleware.initialize(
                symbioticConfig.vaultRegistry,
                symbioticConfig.networkRegistry,
                symbioticConfig.networkMiddlewareService,
                1 hours,
                address(collateral)
            );

            console.log("middleware", address(middleware));
        }

        // deposit collateral into vault
        {
            MockERC20(collateral).mint(getWalletAddress(), 1e18);
            IERC20(collateral).approve(address(vault), type(uint256).max);

            vault.deposit(getWalletAddress(), 1e18);
            console.log("activeBalanceOf", vault.activeBalanceOf(getWalletAddress()));
            vault.withdraw(getWalletAddress(), 1e18);

            vault.deposit(getWalletAddress(), 1000e18);

            // immediateSlasher.slash(getWalletAddress(), 1000e18, 1000e18, 1000e18, "");
        }

        vm.stopBroadcast();
    }
}
