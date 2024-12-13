// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {VersionedInitializable} from '../../misc/aave-upgradeability/VersionedInitializable.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {PoolLogic} from '../libraries/logic/PoolLogic.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {EModeLogic} from '../libraries/logic/EModeLogic.sol';
import {SupplyLogic} from '../libraries/logic/SupplyLogic.sol';
import {FlashLoanLogic} from '../libraries/logic/FlashLoanLogic.sol';
import {BorrowLogic} from '../libraries/logic/BorrowLogic.sol';
import {LiquidationLogic} from '../libraries/logic/LiquidationLogic.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {BridgeLogic} from '../libraries/logic/BridgeLogic.sol';
import {IERC20WithPermit} from '../../interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IACLManager} from '../../interfaces/IACLManager.sol';
import {PoolStorage} from './PoolStorage.sol';

/**
 * @title Pool contract
 * @author Aave
 * @notice Main point of interaction with an Aave protocol's market
 * - Users can:
 *   # Supply
 *   # Withdraw
 *   # Borrow
 *   # Repay
 *   # Enable/disable their supplied assets as collateral
 *   # Liquidate positions
 *   # Execute Flash Loans
 * @dev To be covered by a proxy contract, owned by the PoolAddressesProvider of the specific market
 * @dev All admin functions are callable by the PoolConfigurator contract defined also in the
 *   PoolAddressesProvider
 */
abstract contract Pool is VersionedInitializable, PoolStorage, IPool {
    using ReserveLogic for DataTypes.ReserveData;

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /**
    * @dev Only pool configurator can call functions marked by this modifier.
    */
    modifier onlyPoolConfigurator() {
        _onlyPoolConfigurator();
        _;
    }

    /**
    * @dev Only pool admin can call functions marked by this modifier.
    */
    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    function _onlyPoolConfigurator() internal view virtual {
        require(
            ADDRESSES_PROVIDER.getPoolConfigurator() == msg.sender,
            Errors.CALLER_NOT_POOL_CONFIGURATOR
        );
    }

    function _onlyPoolAdmin() internal view virtual {
        require(
            IACLManager(ADDRESSES_PROVIDER.getACLManager()).isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_POOL_ADMIN
        );
    }

    /**
    * @dev Constructor.
    * @param provider The address of the PoolAddressesProvider contract
    */
    constructor(IPoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
    }

    /**
    * @notice Initializes the Pool.
    * @dev Function is invoked by the proxy contract when the Pool contract is added to the
    * PoolAddressesProvider of the market.
    * @dev Caching the address of the PoolAddressesProvider in order to reduce gas consumption on subsequent operations
    * @param provider The address of the PoolAddressesProvider
    */
    function initialize(IPoolAddressesProvider provider) external virtual;

    /// @inheritdoc IPool
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) public virtual override {
        SupplyLogic.executeSupply(
            _reserves,
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf
            })
        );
    }

    /// @inheritdoc IPool
    function supplyWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public virtual override {
        try IERC20WithPermit(asset).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            permitV,
            permitR,
            permitS
        ) {} catch {}
        SupplyLogic.executeSupply(
            _reserves,
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
            })
        );
    }

    /// @inheritdoc IPool
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) public virtual override returns (uint256) {
        return SupplyLogic.executeWithdraw(
            _reserves,
            DataTypes.ExecuteWithdrawParams({
                asset: asset,
                amount: amount,
                to: to
            })
        );
    }

    /// @inheritdoc IPool
    function borrow(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) public virtual override {
        BorrowLogic.executeBorrow(
            _reserves,
            _reservesList,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteBorrowParams({
                asset: asset,
                user: msg.sender,
                onBehalfOf: onBehalfOf,
                amount: amount,
                reservesCount: _reservesCount,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
                avs: ADDRESSES_PROVIDER.getAvs();
            })
        );
    }

    /// @inheritdoc IPool
    function repay(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) public virtual override returns (uint256) {
        return BorrowLogic.executeRepay(
            _reserves,
            _reservesList,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteRepayParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf
            })
        );
    }

    /// @inheritdoc IPool
    function repayWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public virtual override returns (uint256) {
        try IERC20WithPermit(asset).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            permitV,
            permitR,
            permitS
        ) {} catch {}

        DataTypes.ExecuteRepayParams memory params = DataTypes.ExecuteRepayParams({
            asset: asset,
            amount: amount,
            onBehalfOf: onBehalfOf,
        });

        return BorrowLogic.executeRepay(_reserves, _reservesList, _usersConfig[onBehalfOf], params);
    }

    /// @inheritdoc IPool
    function liquidationCall(
        address debtAsset,
        address user,
        uint256 debtToCover
    ) public virtual override {
        LiquidationLogic.executeLiquidationCall(
            _reserves,
            _reservesList,
            _usersConfig,
            DataTypes.ExecuteLiquidationCallParams({
                reservesCount: _reservesCount,
                debtToCover: debtToCover,
                debtAsset: debtAsset,
                user: user,
                priceOracle: ADDRESSES_PROVIDER.getPriceOracle(),
                priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel(),
                avs: ADDRESSES_PROVIDER.getAvs()
            })
        );
    }

    /// @inheritdoc IPool
    function mintToTreasury(address[] calldata assets) external virtual override {
        PoolLogic.executeMintToTreasury(_reserves, assets, ADDRESSES_PROVIDER.treasury());
    }

    /// @inheritdoc IPool
    function getAccruedToTreasury(
        address asset
    ) external view returns (uint256) {
        return _reserves[asset].accruedToTreasury;
    }

    /// @inheritdoc IPool
    function getReserveData(
        address asset
    ) external view returns (DataTypes.ReserveData memory) {
        return _reserves[asset];
    }

    /// @inheritdoc IPool
    function getUnderlyingBalance(
        address asset
    ) external view virtual override returns (uint128) {
        return _reserves[asset].underlyingBalance;
    }

    /// @inheritdoc IPool
    function getUserAccountData(
        address user
    ) external view virtual override returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
        return PoolLogic.executeGetUserAccountData(
            _reserves,
            _reservesList,
            DataTypes.CalculateUserAccountDataParams({
                userConfig: _usersConfig[user],
                reservesCount: _reservesCount,
                user: user,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                avs: ADDRESSES_PROVIDER.getAvs(),
            })
        );
    }

    /// @inheritdoc IPool
    function getConfiguration(
        address asset
    ) external view virtual override returns (DataTypes.ReserveConfigurationMap memory) {
        return _reserves[asset].configuration;
    }

    /// @inheritdoc IPool
    function getUserConfiguration(
        address user
    ) external view virtual override returns (DataTypes.UserConfigurationMap memory) {
        return _usersConfig[user];
    }

    /// @inheritdoc IPool
    function getReserveNormalizedVariableDebt(
        address asset
    ) external view virtual override returns (uint256) {
        return _reserves[asset].getNormalizedDebt();
    }

    /// @inheritdoc IPool
    function getReservesList() external view virtual override returns (address[] memory) {
        uint256 reservesListCount = _reservesCount;
        uint256 droppedReservesCount = 0;
        address[] memory reservesList = new address[](reservesListCount);

        for (uint256 i = 0; i < reservesListCount; i++) {
            if (_reservesList[i] != address(0)) {
                reservesList[i - droppedReservesCount] = _reservesList[i];
            } else {
                droppedReservesCount++;
            }
        }

        // Reduces the length of the reserves array by `droppedReservesCount`
        assembly {
            mstore(reservesList, sub(reservesListCount, droppedReservesCount))
        }
        return reservesList;
    }

    /// @inheritdoc IPool
    function getReservesCount() external view virtual override returns (uint256) {
        return _reservesCount;
    }

    /// @inheritdoc IPool
    function getReserveAddressById(uint16 id) external view returns (address) {
        return _reservesList[id];
    }

    /// @inheritdoc IPool
    function MAX_NUMBER_RESERVES() public view virtual override returns (uint16) {
        return ReserveConfiguration.MAX_RESERVES_COUNT;
    }

    /// @inheritdoc IPool
    function initReserve(
        address asset,
        address aTokenAddress,
        address variableDebtAddress,
        address interestRateStrategyAddress
    ) external virtual override onlyPoolConfigurator {
        if (
            PoolLogic.executeInitReserve(
                _reserves,
                _reservesList,
                DataTypes.InitReserveParams({
                    asset: asset,
                    aTokenAddress: aTokenAddress,
                    variableDebtAddress: variableDebtAddress,
                    interestRateStrategyAddress: interestRateStrategyAddress,
                    reservesCount: _reservesCount,
                    maxNumberReserves: MAX_NUMBER_RESERVES()
                })
            )
        ) {
        _reservesCount++;
        }
    }

    /// @inheritdoc IPool
    function dropReserve(address asset) external virtual override onlyPoolConfigurator {
        PoolLogic.executeDropReserve(_reserves, _reservesList, asset);
    }

    /// @inheritdoc IPool
    function setReserveInterestRateStrategyAddress(
        address asset,
        address rateStrategyAddress
    ) external virtual override onlyPoolConfigurator {
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);

        _reserves[asset].interestRateStrategyAddress = rateStrategyAddress;
    }

    /// @inheritdoc IPool
    function syncIndexesState(address asset) external virtual override onlyPoolConfigurator {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);
    }

    /// @inheritdoc IPool
    function syncRatesState(address asset) external virtual override onlyPoolConfigurator {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        ReserveLogic.updateInterestRatesAndVirtualBalance(reserve, reserveCache, asset, 0, 0);
    }

    /// @inheritdoc IPool
    function setConfiguration(
        address asset,
        DataTypes.ReserveConfigurationMap calldata configuration
    ) external virtual override onlyPoolConfigurator {
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
        _reserves[asset].configuration = configuration;
    }

    /// @inheritdoc IPool
    function getLiquidationGracePeriod(address asset) external virtual override returns (uint40) {
        return _reserves[asset].liquidationGracePeriodUntil;
    }

    /// @inheritdoc IPool
    function setLiquidationGracePeriod(
        address asset,
        uint40 until
    ) external virtual override onlyPoolConfigurator {
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
        PoolLogic.executeSetLiquidationGracePeriod(_reserves, asset, until);
    }

    /// @inheritdoc IPool
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external virtual override onlyPoolAdmin {
        PoolLogic.executeRescueTokens(token, to, amount);
    }

    /// @inheritdoc IPool
    function getBorrowLogic() external pure returns (address) {
        return address(BorrowLogic);
    }

    /// @inheritdoc IPool
    function getLiquidationLogic() external pure returns (address) {
        return address(LiquidationLogic);
    }

    /// @inheritdoc IPool
    function getPoolLogic() external pure returns (address) {
        return address(PoolLogic);
    }

    /// @inheritdoc IPool
    function getSupplyLogic() external pure returns (address) {
        return address(SupplyLogic);
    }
}