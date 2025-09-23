// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Vault Adapter
/// @author kexley, Cap Labs
/// @notice Utilization rates are sourced from the Vault
interface IVaultAdapter {
    /// @dev Storage for the vault adapter
    /// @param slopeData Slope data for an asset
    /// @param utilizationData Utilization data for an asset
    /// @param maxMultiplier Maximum slope multiplier
    /// @param minMultiplier Minimum slope multiplier
    /// @param rate Rate at which the multiplier shifts
    struct VaultAdapterStorage {
        mapping(address => SlopeData) slopeData;
        mapping(address => mapping(address => UtilizationData)) utilizationData;
        uint256 maxMultiplier;
        uint256 minMultiplier;
        uint256 rate;
    }

    /// @dev Slope data for an asset
    /// @param kink Kink point
    /// @param slope0 Slope before kink
    /// @param slope1 Slope after kink
    struct SlopeData {
        uint256 kink;
        uint256 slope0;
        uint256 slope1;
    }

    /// @dev Slope data for an asset
    /// @param multiplier Multiplier for the asset
    /// @param index Index of the asset
    /// @param lastUpdate Last updated timestamp
    struct UtilizationData {
        uint256 multiplier;
        uint256 index;
        uint256 lastUpdate;
    }

    /// @notice Emitted when slopes are set
    /// @param _asset Asset address
    /// @param _slopes Slope data
    event SetSlopes(address indexed _asset, SlopeData _slopes);

    /// @notice Emitted when limits are set
    /// @param _maxMultiplier Maximum slope multiplier
    /// @param _minMultiplier Minimum slope multiplier
    /// @param _rate Rate at which the multiplier shifts
    event SetLimits(uint256 _maxMultiplier, uint256 _minMultiplier, uint256 _rate);

    /// @dev Invalid kink
    error InvalidKink();

    /// @notice Initialize the vault adapter
    /// @param _accessControl Access control
    function initialize(address _accessControl) external;

    /// @notice Fetch borrow rate for an asset from the Vault
    /// @param _vault Vault address
    /// @param _asset Asset to fetch rate for
    /// @return latestAnswer Borrow rate
    function rate(address _vault, address _asset) external returns (uint256 latestAnswer);

    /// @notice Fetch slopes for an asset
    /// @param _asset Asset to fetch slopes for
    /// @return slopes Slope data
    function slopes(address _asset) external view returns (SlopeData memory slopes);

    /// @notice Fetch maximum multiplier
    /// @return maxMultiplier Maximum multiplier
    function maxMultiplier() external view returns (uint256 maxMultiplier);

    /// @notice Fetch minimum multiplier
    /// @return minMultiplier Minimum multiplier
    function minMultiplier() external view returns (uint256 minMultiplier);

    /// @notice Fetch the rate at which the multiplier shifts
    /// @return multiplierRate Multiplier rate
    function multiplierRate() external view returns (uint256 multiplierRate);

    /// @notice Set utilization slopes for an asset
    /// @param _asset Asset address
    /// @param _slopes Slope data
    function setSlopes(address _asset, SlopeData memory _slopes) external;

    /// @notice Set limits for the utilization multiplier
    /// @param _maxMultiplier Maximum slope multiplier
    /// @param _minMultiplier Minimum slope multiplier
    /// @param _rate Rate at which the multiplier shifts
    function setLimits(uint256 _maxMultiplier, uint256 _minMultiplier, uint256 _rate) external;
}
