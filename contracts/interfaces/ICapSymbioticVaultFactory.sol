// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICapSymbioticVaultFactory {
    /// @notice Creates a new vault
    /// @param _owner The owner of the vault, will manage delegations and set deposit limits
    /// @param asset The asset of the vault
    /// @param _agent The agent of the vault
    /// @param _network The network of the vault
    /// @return vault The address of the new vault
    function createVault(address _owner, address asset, address _agent, address _network)
        external
        returns (address vault, address stakerRewards);
}
