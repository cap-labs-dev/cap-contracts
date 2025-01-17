// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LzUtils } from "../util/LzUtils.sol";

import { CapSymbioticNetworkMiddleware } from "../../contracts/collateral/symbiotic/CapSymbioticNetworkMiddleware.sol";
import { SymbioticUtils } from "../util/SymbioticUtils.sol";
import { WalletUtils } from "../util/WalletUtils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IBurnerRouterFactory } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol";

import { IVaultConfigurator } from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";

import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { IBaseSlasher } from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import { IVetoSlasher } from "@symbioticfi/core/src/interfaces/slasher/IVetoSlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the lockboxes for the cap token and staked cap token
 */
contract DeployMiddleware is Script, WalletUtils, SymbioticUtils {
    SymbioticConfig public symbioticConfig;
    CapSymbioticNetworkMiddleware public middlewareImplementation;

    address public collateral;
    address public burnerRouter;
    uint48 public burnerRouterDelay = 0;
    uint48 public vaultEpochDuration = 1 hours;
    CapSymbioticNetworkMiddleware public middleware;

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }

    function run() public {
        // pull config
        collateral = 0xbDb6B30d716b7a864e0E482C9D703057b46BF218; // mock USDC
        address admin = getWalletAddress();
        symbioticConfig = getConfig();

        vm.startBroadcast();

        // setup vault
        {
            burnerRouter = IBurnerRouterFactory(symbioticConfig.burnerRouterFactory).create(
                IBurnerRouter.InitParams({
                    owner: admin, // address of the router’s owner
                    collateral: collateral, // address of the collateral - wstETH (MUST be the same as for the Vault to connect)
                    delay: burnerRouterDelay, // duration of the receivers’ update delay (= 21 days)
                    globalReceiver: 0x58D347334A5E6bDE7279696abE59a11873294FA4, // address of the pure burner corresponding to the collateral - wstETH_Burner (some collaterals are covered by us; see Deployments page)
                    networkReceivers: new IBurnerRouter.NetworkReceiver[](0), // array with IBurnerRouter.NetworkReceiver elements meaning network-specific receivers
                    operatorNetworkReceivers: new IBurnerRouter.OperatorNetworkReceiver[](0) // array with IBurnerRouter.OperatorNetworkReceiver elements meaning network-specific receivers
                 })
            );

            address[] memory networkLimitSetRoleHolders = new address[](1);
            networkLimitSetRoleHolders[0] = admin;
            address[] memory operatorNetworkSharesSetRoleHolders = new address[](1);
            operatorNetworkSharesSetRoleHolders[0] = admin;
            (address vault, address networkRestakeDelegator, address vetoSlasher) = IVaultConfigurator(
                symbioticConfig.vaultConfigurator
            ).create(
                IVaultConfigurator.InitParams({
                    version: 1, // Vault’s version (= common one)
                    owner: admin, // address of the Vault’s owner (can migrate the Vault to new versions in the future)
                    vaultParams: abi.encode(
                        IVault.InitParams({
                            collateral: collateral, // address of the collateral - wstETH
                            burner: burnerRouter, // address of the deployed burner router
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
                                hook: 0x0000000000000000000000000000000000000000, // address of the hook (if not zero, receives onSlash() call on each slashing)
                                hookSetRoleHolder: admin // address of the hook setter
                             }),
                            networkLimitSetRoleHolders: networkLimitSetRoleHolders, // array of addresses of the network limit setters
                            operatorNetworkSharesSetRoleHolders: operatorNetworkSharesSetRoleHolders // array of addresses of the operator-network shares setters
                         })
                    ),
                    withSlasher: true, // if enable Slasher module
                    slasherIndex: 1, // Slasher’s type (= VetoSlasher)
                    slasherParams: abi.encode(
                        IVetoSlasher.InitParams({
                            baseParams: IBaseSlasher.BaseParams({
                                isBurnerHook: true // if enable the `burner` to receive onSlash() call after each slashing (is needed for the burner router workflow)
                             }),
                            vetoDuration: 86400, // veto duration (= 1 day)
                            resolverSetEpochsDelay: 3 // number of Vault epochs needed for the resolver to be changed
                         })
                    )
                })
            );
        }

        // setup network
        {
            middlewareImplementation = new CapSymbioticNetworkMiddleware();

            middleware = CapSymbioticNetworkMiddleware(_proxy(address(middlewareImplementation)));
            middleware.initialize(symbioticConfig.vaultRegistry, symbioticConfig.networkRegistry, 1 hours, collateral);

            INetworkMiddlewareService(symbioticConfig.networkMiddlewareService).setMiddleware(address(middleware));
        }

        vm.stopBroadcast();
    }
}
