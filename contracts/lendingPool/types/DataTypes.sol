// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataTypes {
    struct ReserveData {
        //stores the reserve configuration
        ReserveConfigurationMap configuration;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint16 id;
        //timestamp until when liquidations are not allowed on the reserve, if set to past liquidations will be allowed
        uint40 liquidationGracePeriodUntil;
        //cToken address
        address cToken;
        //vToken address
        address vToken;
        //address of the interest rate strategy
        address interestRateStrategy;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        //the amount of underlying accounted for by the protocol
        uint128 underlyingBalance;
    }

    struct ReserveConfigurationMap {
        //bit 0-15: LTV
        //bit 16-31: Liq. threshold
        //bit 32-47: Liq. bonus
        //bit 48-55: Decimals
        //bit 56: reserve is active
        //bit 57: reserve is frozen
        //bit 58: borrowing is enabled
        //bit 59: DEPRECATED: stable rate borrowing enabled
        //bit 60: asset is paused
        //bit 61: borrowing in isolation mode is enabled
        //bit 62: siloed borrowing enabled
        //bit 63: flashloaning enabled
        //bit 64-79: reserve factor
        //bit 80-115: borrow cap in whole tokens, borrowCap == 0 => no cap
        //bit 116-151: supply cap in whole tokens, supplyCap == 0 => no cap
        //bit 152-167: liquidation protocol fee
        //bit 168-175: DEPRECATED: eMode category
        //bit 176-211: unbacked mint cap in whole tokens, unbackedMintCap == 0 => minting disabled
        //bit 212-251: debt ceiling for isolation mode with (ReserveConfiguration::DEBT_CEILING_DECIMALS) decimals
        //bit 252: virtual accounting is enabled for the reserve
        //bit 253-255 unused

        uint256 data;
    }

    struct UserConfigurationMap {
        //bitmap of the user's borrows
        uint256 data;
    }

    struct ReserveCache {
        uint256 currScaledVariableDebt;
        uint256 nextScaledVariableDebt;
        uint256 currVariableBorrowIndex;
        uint256 nextVariableBorrowIndex;
        uint256 currVariableBorrowRate;
        ReserveConfigurationMap reserveConfiguration;
        address cToken;
        address vToken;
        uint40 reserveLastUpdateTimestamp;
    }

    struct ExecuteLiquidationCallParams {
        uint256 reservesCount;
        uint256 debtToCover;
        address collateralAsset;
        address debtAsset;
        address user;
        address priceOracle;
        address priceOracleSentinel;
        address avs;
    }

    struct ExecuteSupplyParams {
        address asset;
        uint256 amount;
        address onBehalfOf;
    }

    struct ExecuteBorrowParams {
        address asset;
        address user;
        address onBehalfOf;
        uint256 amount;
        uint256 reservesCount;
        address oracle;
        address priceOracleSentinel;
        address avs;
    }

    struct ExecuteRepayParams {
        address asset;
        uint256 amount;
        address onBehalfOf;
    }

    struct ExecuteWithdrawParams {
        address asset;
        uint256 amount;
        address to;
    }

    struct CalculateUserAccountDataParams {
        UserConfigurationMap userConfig;
        uint256 reservesCount;
        address user;
        address oracle;
        address avs;
    }

    struct ValidateBorrowParams {
        ReserveCache reserveCache;
        UserConfigurationMap userConfig;
        address asset;
        address userAddress;
        uint256 amount;
        uint256 reservesCount;
        address oracle;
        address priceOracleSentinel;
        address avs;
    }

    struct ValidateLiquidationCallParams {
        ReserveCache debtReserveCache;
        uint256 totalDebt;
        uint256 healthFactor;
        address priceOracleSentinel;
        address avs;
    }

    struct CalculateInterestRatesParams {
        uint256 liquidityAdded;
        uint256 liquidityTaken;
        uint256 totalDebt;
        address reserve;
        uint256 underlyingBalance;
    }

    struct InitReserveParams {
        address asset;
        address cToken;
        address vToken;
        address interestRateStrategy;
        uint16 reservesCount;
        uint16 maxNumberReserves;
    }
}