// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Harvester Interface
/// @author weso, Cap Labs
/// @notice Interface for the Harvester contract
interface IHarvester {
    /// @notice Harvest the vault
    /// @param _vault Vault address
    /// @param _asset Asset address
    function harvest(address _vault, address _asset)
        external
        returns (uint256 profit, uint256 loss, uint256 interest);
}
