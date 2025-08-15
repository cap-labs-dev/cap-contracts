// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICapSweeper {
    struct CapSweeperStorage {
        address accessControl;
        address cusd;
        uint256 minSweepAmount;
        uint256 sweepInterval;
        mapping(address => uint256) lastSweep;
    }

    /// @notice Initializes the sweeper
    /// @param _accessControl The access control contract
    /// @param _cusd The cUSD contract
    /// @param _minSweepAmount The minimum amount to sweep
    function initialize(address _accessControl, address _cusd, uint256 _minSweepAmount, uint256 _sweepInterval)
        external;

    /// @notice Sweeps assets from fractional reserve
    /// @param _asset The asset to sweep
    function sweep(address _asset) external;

    /// @notice Sets the sweep interval
    /// @param _sweepInterval The new sweep interval
    function setSweepInterval(uint256 _sweepInterval) external;

    /// @notice Sets the minimum sweep amount
    /// @param _minSweepAmount The new minimum sweep amount
    function setMinSweepAmount(uint256 _minSweepAmount) external;

    /// @notice Returns the checker for the sweep function
    /// @return canExec Whether the sweep function can be executed
    /// @return execPayload The payload to execute the sweep function
    function checker() external view returns (bool canExec, bytes memory execPayload);

    /// @notice Returns the sweep interval
    function sweepInterval() external view returns (uint256);

    /// @notice Returns the minimum sweep amount
    function minSweepAmount() external view returns (uint256);

    /// @notice Returns the last sweep time for an asset
    function lastSweep(address _asset) external view returns (uint256);
}
