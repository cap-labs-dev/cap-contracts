// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAaveDataProvider} from "../../interfaces/IAaveDataProvider.sol";

/// @title Aave Adapter
/// @author kexley, @capLabs
/// @notice Market rates are sourced from Aave
library AaveAdapter {
    /// @notice Fetch borrow rate for an asset from Aave
    /// @param _source Aave pool
    /// @param _asset Asset to fetch rate for
    function rate(address _source, address _asset) external view returns (uint256 latestAnswer) {
        (,,,,,, latestAnswer,,,,,) = IAaveDataProvider(_source).getReserveData(_asset);
    }
}
