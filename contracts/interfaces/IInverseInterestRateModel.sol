// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IInterestRateModel } from "./IInterestRateModel.sol";

/// @title IInverseInterestRateModel
/// @author kexley, Cap Labs
/// @notice Interface for per-market inverse interest rate model based on underwriter credit utilization
interface IInverseInterestRateModel {
    struct InverseInterestRateModelStorage {
        address lender;
        mapping(bytes32 => IInterestRateModel.Slopes) slopes;
        mapping(bytes32 => uint256) index;
        mapping(bytes32 => uint256) lastUpdate;
        mapping(bytes32 => uint256) rate;
    }

    error InvalidSlopes();

    event SetSlopes(bytes32 indexed marketId, IInterestRateModel.Slopes slopes);

    function setSlopes(bytes32 marketId, IInterestRateModel.Slopes memory slopes) external;
    function update(bytes32 marketId) external;
    function index(bytes32 marketId) external view returns (uint256 currentIndex);
    function rate(bytes32 marketId) external view returns (uint256 rate);
    function nextInterestRate(bytes32 marketId) external view returns (uint256 rate);
}
