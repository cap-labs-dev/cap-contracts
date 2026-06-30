// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IInterestRateModel
/// @author kexley, Cap Labs
/// @notice Interface for InterestRateModel contract
interface IInterestRateModel {
    struct Slopes {
        uint256 base;
        uint256 slope0;
        uint256 slope1;
        uint256 kink;
    }

    struct InterestRateModelStorage {
        address stablecoin;
        Slopes variableSlopes;
        Slopes fixedSlopes;
        uint256 lastUpdate;
        uint256 variableRate;
        uint256 fixedRate;
        uint256 variableIndex;
        uint256 fixedIndex;
    }

    event SetVariableSlopes(Slopes slopes);
    event SetFixedSlopes(Slopes slopes);
    event Update(uint256 variableRate, uint256 fixedRate);

    function setVariableSlopes(Slopes memory _slopes) external;
    function setFixedSlopes(Slopes memory _slopes) external;
    function update() external;
    function variableIndex() external view returns (uint256 index);
    function fixedIndex() external view returns (uint256 index);
    function variableRate() external view returns (uint256 rate);
    function fixedRate() external view returns (uint256 rate);
}
