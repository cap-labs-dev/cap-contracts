// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {VersionedInitializable} from '../../misc/aave-upgradeability/VersionedInitializable.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {PoolLogic} from '../libraries/logic/PoolLogic.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {SupplyLogic} from '../libraries/logic/SupplyLogic.sol';
import {BorrowLogic} from '../libraries/logic/BorrowLogic.sol';
import {LiquidationLogic} from '../libraries/logic/LiquidationLogic.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {BridgeLogic} from '../libraries/logic/BridgeLogic.sol';
import {IERC20WithPermit} from '../../interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IACLManager} from '../../interfaces/IACLManager.sol';
import {PoolStorage} from './PoolStorage.sol';

/// @title Pool
/// @author kexley, inspired by Aave
/// @notice Lending pool for covered agents to borrow from
contract Pool is PoolStorage {
    using ReserveLogic for DataTypes.ReserveData;

    /// @dev Only pool configurator can call functions marked by this modifier
    modifier onlyPoolConfigurator() {
        _onlyPoolConfigurator();
        _;
    }

    /// @dev Only pool admin can call functions marked by this modifier
    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    /// @dev Check that the caller is the pool configurator
    function _onlyPoolConfigurator() internal view {
        require(
            ADDRESSES_PROVIDER.getPoolConfigurator() == msg.sender,
            Errors.CALLER_NOT_POOL_CONFIGURATOR
        );
    }

    /// @dev Check that the caller is the pool admin
    function _onlyPoolAdmin() internal view {
        require(
            IACLManager(ADDRESSES_PROVIDER.getACLManager()).isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_POOL_ADMIN
        );
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the pool
    /// @param provider The address of the PoolAddressesProvider contract
    function initialize(IPoolAddressesProvider provider) external initializer {
        ADDRESSES_PROVIDER = provider;
    }

    /// @notice Supply an asset to the pool
    /// @param asset Asset to supply
    /// @param amount Amount of an asset to supply
    /// @param onBehalfOf User to receive the collateral tokens
    function supply(address asset, uint256 amount, address onBehalfOf) public {
        SupplyLogic.executeSupply(
            _reserves,
            DataTypes.ExecuteSupplyParams({asset: asset, amount: amount, onBehalfOf: onBehalfOf})
        );
    }

    /// @notice Supply an asset to the pool using a permit
    /// @param asset Asset to supply
    /// @param amount Amount of an asset to supply
    /// @param onBehalfOf User to receive the collateral tokens
    /// @param deadline Deadline for the signature
    /// @param permitV Part of a signature
    /// @param permitR Part of a signature
    /// @param permitS Part of a signature
    function supplyWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public {
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
            DataTypes.ExecuteSupplyParams({asset: asset, amount: amount, onBehalfOf: onBehalfOf})
        );
    }

    /// @notice Withdraw an asset from the pool
    /// @param asset Asset to withdraw
    /// @param amount Amount to withdraw
    /// @param to Address that will receive the withdrawn asset
    /// @return withdrawAmount Actual amount withdrawn from the pool
    function withdraw(address asset, uint256 amount, address to) public returns (uint256 withdrawAmount) {
        withdrawAmount = SupplyLogic.executeWithdraw(
            _reserves,
            DataTypes.ExecuteWithdrawParams({asset: asset, amount: amount, to: to})
        );
    }

    /// @notice Borrow an asset from the pool
    /// @param asset Asset to borrow
    /// @param amount Amount to borrow
    /// @param onBehalfOf User who will hold the debt
    function borrow(address asset, uint256 amount, address onBehalfOf) public {
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

    /// @notice Repay an asset to the pool
    /// @param asset Asset to repay
    /// @param amount Amount to repay
    /// @param onBehalfOf Address of the user whose debt is being repaid
    /// @param repaid Actual amount repaid
    function repay(address asset, uint256 amount, address onBehalfOf) public returns (uint256 repaid) {
        repaid = BorrowLogic.executeRepay(
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

    /// @notice Repay an asset to the pool using a permit
    /// @param asset Asset to repay
    /// @param amount Amount to repay
    /// @param onBehalfOf Address of the user whose debt is being repaid
    /// @param deadline Deadline for the signature
    /// @param permitV Part of a signature
    /// @param permitR Part of a signature
    /// @param permitS Part of a signature
    /// @param repaid Actual amount repaid
    function repayWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public returns (uint256 repaid) {
        try IERC20WithPermit(asset).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            permitV,
            permitR,
            permitS
        ) {} catch {}

        repaid = BorrowLogic.executeRepay(
            _reserves,
            _reservesList,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteRepayParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
            })
        );
    }

    /// @notice Liquidate a user
    /// @param debtAsset Asset to repay
    /// @param user User to liquidate
    /// @param debtToCover Debt that will be repaid
    function liquidationCall(address debtAsset, address user, uint256 debtToCover) public {
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

    /// @notice Mint cTokens to the treasury address from the accrued debt
    /// @param assets Addresses of underlying assets
    function mintToTreasury(address[] calldata assets) external {
        PoolLogic.executeMintToTreasury(_reserves, assets, ADDRESSES_PROVIDER.treasury());
    }

    /// @notice Fetch amount of debt accrued to treasury
    /// @param assets Address of underlying asset
    /// @param amount Amount accrued to treasury
    function getAccruedToTreasury(address asset) external view returns (uint128 amount) {
        return _reserves[asset].accruedToTreasury;
    }

    /// @notice Fetch reserve data
    /// @param asset Address of underlying asset
    /// @return reserveData Reserve data
    function getReserveData(
        address asset
    ) external view returns (DataTypes.ReserveData memory reserveData) {
        reserve = _reserves[asset];
    }

    /// @notice Fetch supplied balance of the underlying asset in the pool
    /// @param assets Address of underlying asset
    /// @return amount Amount supplied
    function getUnderlyingBalance(address asset) external view returns (uint128 amount) {
        amount = _reserves[asset].underlyingBalance;
    }

    /// @notice Fetch user account data
    /// @param user Address of the user
    /// @return totalCollateralBase Total collateral valued in base currency
    /// @return totalDebtBase Total debt valued in base currency
    /// @return availableBorrowsBase Available borrow power in base currency
    /// @return currentLiquidationThreshold Health factor at which the user will be liquidated
    /// @return ltv Loan-to-value of the user
    /// @return healthFactor Health factor of the user (> 1 is healthy)
    function getUserAccountData(address user) external view returns (
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

    /// @notice Fetch configuration for a reserve
    /// @param asset Address of underlying asset
    /// @return configuration Reserve configuration
    function getConfiguration(
        address asset
    ) external view returns (DataTypes.ReserveConfigurationMap memory configuration) {
        configuration = _reserves[asset].configuration;
    }

    /// @notice Fetch configuration for a user
    /// @param user Address of user
    /// @return configuration User configuration
    function getUserConfiguration(
        address user
    ) external view returns (DataTypes.UserConfigurationMap memory configuration) {
        configuration = _usersConfig[user];
    }

    /// @notice Fetch normalized debt for a reserve
    /// @param asset Address of underlying asset
    /// @return normalizedDebt Normalized debt of a reserve
    function getReserveNormalizedVariableDebt(
        address asset
    ) external view returns (uint256 normalizedDebt) {
        normalizedDebt = _reserves[asset].getNormalizedDebt();
    }

    /// @notice Fetch all non-dropped reserves
    /// @return reserves List of non-dropped reserve addresses
    function getReservesList() external view returns (address[] memory reserves) {
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
        reserves = reservesList;
    }

    /// @notice Returns the number of initialized reserves, including dropped reserves
    /// @return count Number of reserves
    function getReservesCount() external view returns (uint256 count) {
        count = _reservesCount;
    }

    /// @notice Returns the address of the underlying asset of a reserve by the reserve id as stored in the DataTypes.ReserveData struct
    /// @param id The id of the reserve as stored in the DataTypes.ReserveData struct
    /// @return reserve The address of the reserve associated with id
    function getReserveAddressById(uint16 id) external view returns (address reserve) {
        return _reservesList[id];
    }

    /// @notice Maximum number of reserves that can be initialized
    /// @return max Maximum number of initializable reserves
    function MAX_NUMBER_RESERVES() public view virtual override returns (uint16 max) {
        max = ReserveConfiguration.MAX_RESERVES_COUNT;
    }

    /// @notice Pool configurator calls this to initialize a reserve
    /// @param asset Asset to be used as the underlying
    /// @param cToken cToken address for the reserve
    /// @param vToken vToken for the reserve
    /// @param interestRateStrategy Interest rate strategy for the reserve
    function initReserve(
        address asset,
        address cToken,
        address vToken,
        address interestRateStrategy
    ) external onlyPoolConfigurator {
        if (
            PoolLogic.executeInitReserve(
                _reserves,
                _reservesList,
                DataTypes.InitReserveParams({
                    asset: asset,
                    cTokenImplementation: ADDRESS_PROVIDER.getCTokenImplementation(),
                    vTokenImplementation: ADDRESS_PROVIDER.getVTokenImplementation(),
                    interestRateStrategy: ADDRESS_PROVIDER.getInterestRateStrategy(),
                    reservesCount: _reservesCount,
                    maxNumberReserves: MAX_NUMBER_RESERVES()
                })
            )
        ) {
            _reservesCount++;
        }
    }

    /// @notice Pool configurator calls this to drop a reserve
    /// @param asset Underlying asset of the dropped reserve
    function dropReserve(address asset) external virtual override onlyPoolConfigurator {
        PoolLogic.executeDropReserve(_reserves, _reservesList, asset);
    }

    /// @notice Pool configurator calls this to set the interest rate strategy for a reserve
    /// @param asset Underlying asset of the reserve
    /// @param interestRateStrategy Address of the interest rate strategy
    function setReserveInterestRateStrategy(
        address asset,
        address interestRateStrategy
    ) external onlyPoolConfigurator {
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);

        _reserves[asset].interestRateStrategy = interestRateStrategy;
    }

    /// @notice Pool configurator calls this to update the debt index for a reserve
    /// @dev Used by the configurator when needing to update the interest rate strategy data
    /// @param asset Underlying asset of the reserve
    function syncIndexesState(address asset) external onlyPoolConfigurator {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);
    }

    /// @notice Pool configurator calls this to update the interest rate
    /// @dev Used by the configurator when needing to update the interest rate strategy data
    /// @param asset Underlying asset of the reserve
    function syncRatesState(address asset) external onlyPoolConfigurator {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        DataTypes.ReserveCache memory reserveCache = reserve.cache();

        ReserveLogic.updateInterestRatesAndVirtualBalance(reserve, reserveCache, asset, 0, 0);
    }

    /// @notice Pool configurator calls this to set the configuration bitmap of a reserve
    /// @param asset Underlying asset of the reserve
    /// @param configuration New configuration bitmap
    function setConfiguration(
        address asset,
        DataTypes.ReserveConfigurationMap calldata configuration
    ) external onlyPoolConfigurator {
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
        _reserves[asset].configuration = configuration;
    }

    /// @notice Fetch the grace period for liquidations of a reserve
    /// @param asset Underlying asset of the reserve
    /// @return gracePeriod Grace period for liquidations
    function getLiquidationGracePeriod(address asset) external returns (uint40 period) {
        period = _reserves[asset].liquidationGracePeriodUntil;
    }

    /// @notice Pool configurator calls this to set the grace period for liquidations of a reserve
    /// @param asset Underlying asset of the reserve
    /// @return until Grace period for liquidations
    function setLiquidationGracePeriod(address asset, uint40 until) external onlyPoolConfigurator {
        require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
        PoolLogic.executeSetLiquidationGracePeriod(_reserves, asset, until);
    }

    /// @notice Pool admin can rescue tokens sent to this contract
    /// @param token Token to be rescued
    /// @param to Receiver of the tokens
    /// @param amount Amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyPoolAdmin {
        PoolLogic.executeRescueTokens(token, to, amount);
    }

    /// @notice Fetch external library address of supply logic
    /// @return supplyLogic External library address
    function getSupplyLogic() external pure returns (address supplyLogic) {
        supplyLogic = address(SupplyLogic);
    }

    /// @notice Fetch external library address of borrow logic
    /// @return borrowLogic External library address
    function getBorrowLogic() external pure returns (address borrowLogic) {
        borrowLogic = address(BorrowLogic);
    }

    /// @notice Fetch external library address of liquidation logic
    /// @return liquidationLogic External library address
    function getLiquidationLogic() external pure returns (address liquidationLogic) {
        liquidationLogic = address(LiquidationLogic);
    }

    /// @notice Fetch external library address of pool logic
    /// @return poolLogic External library address
    function getPoolLogic() external pure returns (address poolLogic) {
        poolLogic = address(PoolLogic);
    }
}