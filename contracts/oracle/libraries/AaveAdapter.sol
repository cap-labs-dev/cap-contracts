// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAaveDataProvider } from "../../interfaces/IAaveDataProvider.sol";

/// @title Aave Adapter
/// @author kexley, Cap Labs
/// @notice Market rates are sourced from Aave
library AaveAdapter {
    /// @notice Fetch borrow rate for an asset from Aave
    /// @param _aaveDataProvider Aave data provider
    /// @param _asset Asset to fetch rate for
    /// @return latestAnswer Latest borrow rate for the asset
    function rate(address _aaveDataProvider, address _asset) external view returns (uint256 latestAnswer) {
        (,,,,,, latestAnswer,,,,,) = IAaveDataProvider(_aaveDataProvider).getReserveData(_asset);
    }
}
