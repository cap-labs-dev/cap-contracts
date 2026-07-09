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

    struct Storage {
        address stablecoin;
        Slopes variableSlopes;
        Slopes fixedSlopes;
        uint256 lastUpdate;
        uint256 variableRate;
        uint256 fixedRate;
        uint256 variableIndex;
        uint256 fixedIndex;
        mapping(address => Slopes) marketSlopes;
        mapping(address => uint256) marketIndex;
        mapping(address => uint256) lastMarketUpdate;
        mapping(address => uint256) marketRate;
        mapping(address => bool) marketVariable;
    }

    error InvalidSlopes();

    event SetVariableSlopes(Slopes slopes);
    event SetFixedSlopes(Slopes slopes);
    event SetUnderwriterSlopes(address market, Slopes slopes);

    function setVariableSlopes(Slopes memory _slopes) external;
    function setFixedSlopes(Slopes memory _slopes) external;
    function setUnderwriterSlopes(address market, Slopes memory _slopes) external;
    function variableIndex() external view returns (uint256 index);
    function fixedIndex() external view returns (uint256 index);
    function variableRate() external view returns (uint256 rate);
    function fixedRate() external view returns (uint256 rate);
    function underwriterRate(address market) external view returns (uint256 rate);
    function update() external;
    function update(address market) external;
    function underwriterIndex(address market) external view returns (uint256 index);
    function nextInterestRate(address market) external view returns (uint256 rate);
}
