// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title cUSD Rate Provider interface
/// @author weso, Cap Labs
/// @notice Interface for the cUSD Rate Provider contract
interface ICapUSDRateProvider {
    /// @notice Storage for the cUSD Rate Provider
    /// @param porFeed The address of the PoR feed
    /// @param cusd The address of the cUSD token
    struct CapUSDRateProviderStorage {
        address porFeed;
        address cusd;
    }

    /// @notice Initialize the cUSD Rate Provider
    /// @param _accessControl The address of the access control contract
    /// @param _porFeed The address of the PoR feed
    /// @param _cusd The address of the cUSD token
    function initialize(address _accessControl, address _porFeed, address _cusd) external;

    /// @notice Get the rate of cUSD
    /// @return The rate of cUSD
    function getRate() external view returns (uint256);
}
