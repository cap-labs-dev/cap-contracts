// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { CapSymbioticNetworkMiddleware } from "../../contracts/collateral/symbiotic/CapSymbioticNetworkMiddleware.sol";
import { Test } from "forge-std/Test.sol";

import { SymbioticUtils } from "../../script/util/SymbioticUtils.sol";
import { MockERC20 } from "../../test/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IBurnerRouterFactory } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol";

import { IOperatorRegistry } from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";

import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { IVaultConfigurator } from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";
import { IDelegatorHook } from "@symbioticfi/core/src/interfaces/delegator/IDelegatorHook.sol";
import { SimpleBurner } from "@symbioticfi/core/test/mocks/SimpleBurner.sol";

import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";

import { ProxyUtils } from "../../script/util/ProxyUtils.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { IBaseSlasher } from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { console } from "forge-std/console.sol";

contract CapSymbioticMiddlewareTest is Test, SymbioticUtils, ProxyUtils {
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

    address public user_agent;
    address public user_restaker;
    address public user_cap_admin;
    address public user_vault_admin;
    address public cap_network_address;

    function setUp() public {
        vm.createSelectFork("https://sepolia.gateway.tenderly.co", 7512723);

        // setup users
        {
            user_vault_admin = makeAddr("vault_admin");
            user_agent = makeAddr("agent");
            user_restaker = makeAddr("restaker");
            user_cap_admin = makeAddr("cap_admin");
            cap_network_address = makeAddr("cap_network_address");

            collateral = new MockERC20("Mock USDC", "USDC");
            MockERC20(collateral).mint(user_restaker, 10_000_000e18);

            symbioticConfig = getConfig();
        }

        // deploy a vault
        {
            vm.startPrank(user_vault_admin);

            // deploy a default burner
            address defaultBurner = address(new SimpleBurner(address(collateral)));

            // burner router setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#1-burner-router
            // https://docs.symbiotic.fi/guides/vault-deployment#network-specific-burners
            burnerRouter = IBurnerRouter(
                IBurnerRouterFactory(symbioticConfig.burnerRouterFactory).create(
                    IBurnerRouter.InitParams({
                        owner: user_vault_admin, // address of the router’s owner
                        collateral: address(collateral), // address of the collateral - wstETH (MUST be the same as for the Vault to connect)
                        delay: burnerRouterDelay, // duration of the receivers’ update delay (= 21 days)
                        globalReceiver: defaultBurner, // address of the pure burner corresponding to the collateral - wstETH_Burner (some collaterals are covered by us; see Deployments page)
                        networkReceivers: new IBurnerRouter.NetworkReceiver[](0), // array with IBurnerRouter.NetworkReceiver elements meaning network-specific receivers
                        operatorNetworkReceivers: new IBurnerRouter.OperatorNetworkReceiver[](0) // array with IBurnerRouter.OperatorNetworkReceiver elements meaning network-specific receivers
                     })
                )
            );

            // vault setup
            // https://docs.symbiotic.fi/guides/vault-deployment/#vault
            address[] memory networkLimitSetRoleHolders = new address[](1);
            networkLimitSetRoleHolders[0] = user_vault_admin;

            address[] memory operatorNetworkSharesSetRoleHolders = new address[](1);
            operatorNetworkSharesSetRoleHolders[0] = user_vault_admin;

            (address _vault, address _networkRestakeDelegator, address _immediateSlasher) = IVaultConfigurator(
                symbioticConfig.vaultConfigurator
            ).create(
                IVaultConfigurator.InitParams({
                    version: 1, // Vault’s version (= common one)
                    owner: user_vault_admin, // address of the Vault’s owner (can migrate the Vault to new versions in the future)
                    vaultParams: abi.encode(
                        IVault.InitParams({
                            collateral: address(collateral), // address of the collateral - wstETH
                            burner: address(burnerRouter), // address of the deployed burner router
                            epochDuration: vaultEpochDuration, // duration of the Vault epoch in seconds (= 7 days)
                            depositWhitelist: false, // if enable deposit whitelisting
                            isDepositLimit: false, // if enable deposit limit
                            depositLimit: 0, // deposit limit
                            defaultAdminRoleHolder: user_vault_admin, // address of the Vault’s admin (can manage all roles)
                            depositWhitelistSetRoleHolder: user_vault_admin, // address of the enabler/disabler of the deposit whitelisting
                            depositorWhitelistRoleHolder: user_vault_admin, // address of the depositors whitelister
                            isDepositLimitSetRoleHolder: user_vault_admin, // address of the enabler/disabler of the deposit limit
                            depositLimitSetRoleHolder: user_vault_admin // address of the deposit limit setter
                         })
                    ),
                    delegatorIndex: uint64(DelegatorType.NETWORK_RESTAKE), // Delegator’s type (= NetworkRestakeDelegator)
                    delegatorParams: abi.encode(
                        INetworkRestakeDelegator.InitParams({
                            baseParams: IBaseDelegator.BaseParams({
                                defaultAdminRoleHolder: user_vault_admin, // address of the Delegator’s admin (can manage all roles)
                                hook: 0x0000000000000000000000000000000000000000, // address of the hook (if not zero, receives onSlash() call on each slashing)
                                hookSetRoleHolder: user_vault_admin // address of the hook setter
                             }),
                            networkLimitSetRoleHolders: networkLimitSetRoleHolders, // array of addresses of the network limit setters
                            operatorNetworkSharesSetRoleHolders: operatorNetworkSharesSetRoleHolders // array of addresses of the operator-network shares setters
                         })
                    ),
                    withSlasher: true, // if enable Slasher module
                    slasherIndex: uint64(SlasherType.INSTANT), // Slasher’s type (0 = ImmediateSlasher, 1 = VetoSlasher)
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
                        defaultAdminRoleHolder: user_cap_admin, // address of the main admin (can manage all roles)
                        adminFeeClaimRoleHolder: user_cap_admin, // address of the admin fee claimer
                        adminFeeSetRoleHolder: user_cap_admin // address of the admin fee setter
                     })
                )
            );

            vm.stopPrank();
        }

        // init the cap network (middleware + registry)
        {
            vm.startPrank(cap_network_address);

            middlewareImplementation = new CapSymbioticNetworkMiddleware();
            middleware = CapSymbioticNetworkMiddleware(_proxy(address(middlewareImplementation)));

            middleware.initialize(cap_network_address, symbioticConfig.vaultRegistry, vaultEpochDuration);

            INetworkRegistry(symbioticConfig.networkRegistry).registerNetwork();
            INetworkMiddlewareService(symbioticConfig.networkMiddlewareService).setMiddleware(address(middleware));

            vm.stopPrank();
        }

        // cap network gets whitelisted on the vault
        {
            vm.startPrank(user_vault_admin);

            burnerRouter.setNetworkReceiver(cap_network_address, address(middleware));
            burnerRouter.acceptNetworkReceiver(cap_network_address);

            vm.stopPrank();
        }

        // manage the middleware:
        // register the vault in the network config
        {
            vm.startPrank(user_cap_admin);

            // register the vault in the network
            middleware.registerVault(address(vault));

            vm.stopPrank();
        }

        // agent registers as an operator
        {
            vm.startPrank(user_agent);

            IOperatorRegistry(symbioticConfig.operatorRegistry).registerOperator();

            vm.stopPrank();
        }

        /// OPT-INS
        // https://docs.symbiotic.fi/modules/registries#opt-ins-in-symbiotic

        // 1. Operator to Vault Opt-in
        // Operators use the VaultOptInService to opt into specific vaults. This allows them to receive stake allocations from these vaults.
        {
            vm.startPrank(user_agent);
            IOptInService(symbioticConfig.vaultOptInService).optIn(address(vault));
            vm.stopPrank();
        }

        // 2. Operator to Network Opt-in
        // Through the NetworkOptInService, operators can opt into networks they wish to work with. This signifies their willingness to provide services to these networks.
        {
            vm.startPrank(user_agent);
            IOptInService(symbioticConfig.networkOptInService).optIn(cap_network_address);
            vm.stopPrank();
        }

        // 3. Network to Vault Opt-in
        // Networks can opt into vaults to set maximum stake limits they’re willing to accept. This is done using the setMaxNetworkLimit function of the vault’s delegator.
        {
            vm.startPrank(cap_network_address);
            INetworkRestakeDelegator(networkRestakeDelegator).setMaxNetworkLimit(
                middleware.subnetworkIdentifier(), type(uint256).max
            );
            vm.stopPrank();
        }

        // 4. Vault to Network Opt-in
        // Vaults can opt into networks by setting non-zero limits.
        // https://docs.symbiotic.fi/modules/registries/#vault-allocation-to-networks
        // After a network opts into a vault, the vault manager can allocate stake to the network:
        // - The vault manager reviews the conditions proposed by the network (resolvers and limits).
        // - If agreed, the vault manager allocates stake by calling:
        // `INetworkRestakeDelegator(IVault(vault).delegator).setNetworkLimit(subnetwork, amount)`
        // Where amount is the total network stake limit, which can be set up to the MAX_STAKE defined by the network.
        {
            vm.startPrank(user_vault_admin);

            INetworkRestakeDelegator(networkRestakeDelegator).setNetworkLimit(
                middleware.subnetwork(), type(uint256).max
            );

            vm.stopPrank();
        }

        // 5. Vault to Operators Opt-in
        // Vaults can opt into operators by setting non-zero limits.
        {
            vm.startPrank(user_vault_admin);

            // actually delegate to the agent
            networkRestakeDelegator.setOperatorNetworkShares(middleware.subnetwork(), user_agent, type(uint256).max);

            vm.stopPrank();
        }

        // someone deposits collateral into the vault
        {
            vm.startPrank(user_restaker);

            IERC20(collateral).approve(address(vault), 1000e18);
            vault.deposit(user_restaker, 1000e18);

            vm.stopPrank();
        }

        // change the epoch
        vm.warp(block.timestamp + 1 days);
    }

    function test_slash_sends_funds_to_middleware() public {
        // it is slashable
        {
            vm.startPrank(user_cap_admin);

            assertEq(IERC20(collateral).balanceOf(address(middleware)), 0);

            middleware.slashAgent(user_agent, address(collateral), 10e18);

            assertEq(IERC20(collateral).balanceOf(address(middleware)), 10e18);

            vm.stopPrank();
        }
    }
}
