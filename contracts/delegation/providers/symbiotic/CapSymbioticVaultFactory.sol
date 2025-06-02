// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IBurnerRouterFactory } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol";
import { IVaultConfigurator } from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkRestakeDelegator } from "@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol";

import { IBaseSlasher } from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

contract CapSymbioticVaultFactory is Ownable {
    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }

    enum SlasherType {
        INSTANT,
        VETO
    }

    IVaultConfigurator public immutable vaultConfigurator;
    IBurnerRouterFactory public immutable burnerRouterFactory;

    address public immutable middleware;

    mapping(address => address) public ownerToVault;

    uint48 public epochDuration;

    constructor(address _vaultConfigurator, address _burnerRouterFactory, address _middleware, uint48 _epochDuration)
        Ownable(msg.sender)
    {
        vaultConfigurator = IVaultConfigurator(_vaultConfigurator);
        burnerRouterFactory = IBurnerRouterFactory(_burnerRouterFactory);
        middleware = _middleware;
        epochDuration = _epochDuration;
    }

    function createVault(address _owner, address collateral) external returns (address vault) {
        address burner = _deployBurner(collateral);
        IVaultConfigurator.InitParams memory params = IVaultConfigurator.InitParams({
            version: 1,
            owner: _owner,
            vaultParams: abi.encode(
                IVault.InitParams({
                    collateral: collateral,
                    burner: burner,
                    epochDuration: epochDuration,
                    depositWhitelist: true,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: _owner,
                    depositWhitelistSetRoleHolder: _owner,
                    depositorWhitelistRoleHolder: _owner,
                    isDepositLimitSetRoleHolder: _owner,
                    depositLimitSetRoleHolder: _owner
                })
            ),
            delegatorIndex: uint64(DelegatorType.NETWORK_RESTAKE),
            delegatorParams: abi.encode(
                INetworkRestakeDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: _owner,
                        hook: address(0),
                        hookSetRoleHolder: _owner
                    }),
                    networkLimitSetRoleHolders: new address[](0),
                    operatorNetworkSharesSetRoleHolders: new address[](0)
                })
            ),
            withSlasher: true,
            slasherIndex: uint64(SlasherType.INSTANT),
            slasherParams: abi.encode(ISlasher.InitParams({ baseParams: IBaseSlasher.BaseParams({ isBurnerHook: true }) }))
        });

        (vault,,) = vaultConfigurator.create(params);
    }

    function _deployBurner(address _collateral) internal returns (address) {
        return burnerRouterFactory.create(
            IBurnerRouter.InitParams({
                owner: address(0),
                collateral: _collateral,
                delay: 0,
                globalReceiver: middleware,
                networkReceivers: new IBurnerRouter.NetworkReceiver[](0),
                operatorNetworkReceivers: new IBurnerRouter.OperatorNetworkReceiver[](0)
            })
        );
    }
}
