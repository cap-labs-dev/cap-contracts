// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockAaveDataProvider {
    struct ReserveData {
        uint256 unbacked;
        uint256 accruedToTreasuryScaled;
        uint256 totalAToken;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 liquidityRate;
        uint256 variableBorrowRate;
        uint256 stableBorrowRate;
        uint256 averageStableBorrowRate;
        uint256 liquidityIndex;
        uint256 variableBorrowIndex;
        uint40 lastUpdateTimestamp;
    }

    mapping(address => ReserveData) private reserveData;

    function setReserveData(
        address asset,
        uint256 unbacked,
        uint256 accruedToTreasuryScaled,
        uint256 totalAToken,
        uint256 totalVariableDebt,
        uint256 liquidityRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex,
        uint40 lastUpdateTimestamp
    ) external {
        reserveData[asset] = ReserveData({
            unbacked: unbacked,
            accruedToTreasuryScaled: accruedToTreasuryScaled,
            totalAToken: totalAToken,
            totalStableDebt: 0, // Not used in the interface
            totalVariableDebt: totalVariableDebt,
            liquidityRate: liquidityRate,
            variableBorrowRate: variableBorrowRate,
            stableBorrowRate: 0, // Not used in the interface
            averageStableBorrowRate: 0, // Not used in the interface
            liquidityIndex: liquidityIndex,
            variableBorrowIndex: variableBorrowIndex,
            lastUpdateTimestamp: lastUpdateTimestamp
        });
    }

    function getReserveData(address asset)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint40
        )
    {
        ReserveData memory data = reserveData[asset];
        return (
            data.unbacked,
            data.accruedToTreasuryScaled,
            data.totalAToken,
            data.totalStableDebt,
            data.totalVariableDebt,
            data.liquidityRate,
            data.variableBorrowRate,
            data.stableBorrowRate,
            data.averageStableBorrowRate,
            data.liquidityIndex,
            data.variableBorrowIndex,
            data.lastUpdateTimestamp
        );
    }
}
