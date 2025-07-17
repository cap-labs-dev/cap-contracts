// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapSymbioticVaultFactory } from "../../../interfaces/ICapSymbioticVaultFactory.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IBurnerRouterFactory } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol";
import { IVaultConfigurator } from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";

import { IBaseSlasher } from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";

/// @title Cap Symbiotic Vault Factory
/// @author Cap Labs
/// @notice This contract creates new vaults compliant with the cap system
contract CapSymbioticVaultFactory is ICapSymbioticVaultFactory {
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
    IDefaultStakerRewardsFactory public immutable defaultStakerRewardsFactory;
    address public immutable middleware;
    uint48 public epochDuration;

    constructor(
        address _vaultConfigurator,
        address _burnerRouterFactory,
        address _defaultStakerRewardsFactory,
        address _middleware
    ) {
        vaultConfigurator = IVaultConfigurator(_vaultConfigurator);
        burnerRouterFactory = IBurnerRouterFactory(_burnerRouterFactory);
        defaultStakerRewardsFactory = IDefaultStakerRewardsFactory(_defaultStakerRewardsFactory);
        middleware = _middleware;
        epochDuration = 7 days;
    }

    /// @inheritdoc ICapSymbioticVaultFactory
    function createVault(address _owner, address _asset, address _agent, address _network)
        external
        returns (address vault, address delegator, address burner, address slasher, address stakerRewards)
    {
        burner = _deployBurner(_asset);

        address[] memory limitSetter = new address[](1);
        limitSetter[0] = _owner;

        IVaultConfigurator.InitParams memory params = IVaultConfigurator.InitParams({
            version: 1,
            owner: address(0),
            vaultParams: abi.encode(
                IVault.InitParams({
                    collateral: _asset,
                    burner: burner,
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: _owner,
                    depositorWhitelistRoleHolder: _owner,
                    isDepositLimitSetRoleHolder: _owner,
                    depositLimitSetRoleHolder: _owner
                })
            ),
            delegatorIndex: uint64(DelegatorType.OPERATOR_NETWORK_SPECIFIC),
            delegatorParams: abi.encode(
                IOperatorNetworkSpecificDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: address(0),
                        hook: address(0),
                        hookSetRoleHolder: address(0)
                    }),
                    network: _network,
                    operator: _agent
                })
            ),
            withSlasher: true,
            slasherIndex: uint64(SlasherType.INSTANT),
            slasherParams: abi.encode(ISlasher.InitParams({ baseParams: IBaseSlasher.BaseParams({ isBurnerHook: true }) }))
        });

        (vault, delegator, slasher) = vaultConfigurator.create(params);

        stakerRewards = defaultStakerRewardsFactory.create(
            IDefaultStakerRewards.InitParams({
                vault: vault,
                adminFee: 0,
                defaultAdminRoleHolder: _owner,
                adminFeeClaimRoleHolder: _owner,
                adminFeeSetRoleHolder: _owner
            })
        );
    }

    // @dev Deploys a new burner router
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
