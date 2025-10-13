// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ICapLiquidator
/// @author kexley, Cap Labs
/// @notice Interface for the CapLiquidator contract
interface ICapLiquidator {
    /// @notice Invalid flash loan
    error InvalidFlashLoan();

    /// @notice Invalid collateral
    error InvalidCollateral();

    /// @notice Liquidated
    event Liquidated(address indexed agent, address indexed asset, address indexed collateral, uint256 excessAmount);

    /// @notice Excess receiver set
    event ExcessReceiverSet(address excessReceiver);

    /// @dev Storage for the CapLiquidator contract
    /// @param lender Lender address
    /// @param balancerVault Balancer vault address
    /// @param excessReceiver Excess receiver address
    /// @param router Router address
    /// @param delegation Delegation address
    /// @param flashInProgress Flash in progress lock
    struct CapLiquidatorStorage {
        address lender;
        address delegation;
        address balancerVault;
        address excessReceiver;
        address router;
        bool flashInProgress;
    }

    /// @notice Initialize the CapLiquidator contract
    /// @param _accessControl Access control address
    /// @param _lender Lender address
    /// @param _delegation Delegation address
    /// @param _balancerVault Balancer vault address
    /// @param _excessReceiver Excess receiver address
    /// @param _router Router address
    function initialize(
        address _accessControl,
        address _lender,
        address _delegation,
        address _balancerVault,
        address _excessReceiver,
        address _router
    ) external;

    /// @notice Liquidate an asset
    /// @param _agent Agent address
    /// @param _asset Asset address
    /// @param _amount Amount of asset to liquidate
    function liquidate(address _agent, address _asset, uint256 _amount) external;

    /// @notice Receive a flash loan from Balancer
    /// @param _assets Assets to be liquidated
    /// @param _amounts Amounts of assets to be liquidated
    /// @param _feeAmounts Fee amounts of assets
    /// @param _userData User data
    function receiveFlashLoan(
        address[] memory _assets,
        uint256[] memory _amounts,
        uint256[] memory _feeAmounts,
        bytes memory _userData
    ) external;

    /// @notice Gelato checker
    /// @param _agent Agent address
    /// @param _asset Asset address
    /// @return canExec Whether the checker can execute
    /// @return execPayload The payload to execute
    function checker(address _agent, address _asset) external view returns (bool canExec, bytes memory execPayload);

    /// @notice Set the excess receiver
    /// @param _excessReceiver Excess receiver address
    function setExcessReceiver(address _excessReceiver) external;
}
