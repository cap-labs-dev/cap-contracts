// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IPool} from '../../../interfaces/IPool.sol';
import {IInitializableAToken} from '../../../interfaces/IInitializableAToken.sol';
import {IInitializableDebtToken} from '../../../interfaces/IInitializableDebtToken.sol';
import {InitializableImmutableAdminUpgradeabilityProxy} from '../../../misc/aave-upgradeability/InitializableImmutableAdminUpgradeabilityProxy.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {Errors} from '../helpers/Errors.sol';
import {ConfiguratorInputTypes} from '../types/ConfiguratorInputTypes.sol';
import {IERC20Detailed} from '../../../dependencies/openzeppelin/contracts/IERC20Detailed.sol';

/// @title ConfiguratorLogic library
/// @author kexley, inspired by Aave
/// @notice Implements the functions to initialize reserves and update aTokens and debtTokens
library ConfiguratorLogic {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    // See `IPoolConfigurator` for descriptions
    event ReserveInitialized(
        address indexed asset,
        address indexed cToken,
        address vToken,
        address interestRateStrategy
    );

    /// @notice Initialize a reserve by creating and initializing aToken and variable debt token
    /// @dev Emits the `ReserveInitialized` event
    /// @param input The needed parameters for the initialization
    function executeInitReserve(
        ConfiguratorInputTypes.InitReserveInput calldata input
    ) external {
        // It is an assumption that the asset listed is non-malicious, and the external call doesn't create re-entrancies
        uint8 underlyingAssetDecimals = IERC20Detailed(input.underlyingAsset).decimals();
        require(underlyingAssetDecimals > 5, Errors.INVALID_DECIMALS);

        address cToken = CloneLogic.clone(params.cTokenImplementation, address(this), params.asset);
        address vToken = CloneLogic.clone(params.vTokenImplementation, address(this), params.asset);

        address aTokenProxyAddress = _initTokenWithProxy(
            input.aTokenImpl,
            abi.encodeWithSelector(
                IInitializableAToken.initialize.selector,
                pool,
                input.treasury,
                input.underlyingAsset,
                input.incentivesController,
                underlyingAssetDecimals,
                input.aTokenName,
                input.aTokenSymbol,
                input.params
            )
        );

        address variableDebtTokenProxyAddress = _initTokenWithProxy(
            input.variableDebtTokenImpl,
            abi.encodeWithSelector(
                IInitializableDebtToken.initialize.selector,
                pool,
                input.underlyingAsset,
                input.incentivesController,
                underlyingAssetDecimals,
                input.variableDebtTokenName,
                input.variableDebtTokenSymbol,
                input.params
            )
        );

        pool.initReserve(
            input.underlyingAsset,
            aTokenProxyAddress,
            variableDebtTokenProxyAddress,
            input.interestRateStrategyAddress
        );

        DataTypes.ReserveConfigurationMap memory currentConfig = DataTypes.ReserveConfigurationMap(0);

        currentConfig.setDecimals(underlyingAssetDecimals);

        currentConfig.setActive(true);
        currentConfig.setPaused(false);
        currentConfig.setFrozen(false);

        pool.setConfiguration(input.underlyingAsset, currentConfig);

        IReserveInterestRateStrategy(input.interestRateStrategyAddress).setInterestRateParams(
            input.underlyingAsset,
            input.interestRateData
        );

        emit ReserveInitialized(
            input.underlyingAsset,
            aTokenProxyAddress,
            address(0),
            variableDebtTokenProxyAddress,
            input.interestRateStrategyAddress
        );
    }
}
