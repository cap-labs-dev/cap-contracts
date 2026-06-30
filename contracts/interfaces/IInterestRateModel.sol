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
        address lender;
        Slopes variableSlopes;
        Slopes fixedSlopes;
        uint256 lastUpdate;
        uint256 variableRate;
        uint256 fixedRate;
        uint256 variableIndex;
        uint256 fixedIndex;
        mapping(bytes32 => Slopes) marketSlopes;
        mapping(bytes32 => uint256) marketIndex;
        mapping(bytes32 => uint256) lastMarketUpdate;
        mapping(bytes32 => uint256) marketRate;
    }

    error InvalidSlopes();

    event SetVariableSlopes(Slopes slopes);
    event SetFixedSlopes(Slopes slopes);
    event SetMarketSlopes(bytes32 marketId, Slopes slopes);

    function setVariableSlopes(Slopes memory _slopes) external;
    function setFixedSlopes(Slopes memory _slopes) external;
    function setMarketSlopes(bytes32 marketId, Slopes memory _slopes) external;
    function variableIndex() external view returns (uint256 index);
    function fixedIndex() external view returns (uint256 index);
    function index(bytes32 marketId) external view returns (uint256 index);
    function variableRate() external view returns (uint256 rate);
    function fixedRate() external view returns (uint256 rate);
    function rate(bytes32 marketId) external view returns (uint256 rate);
    function update() external;
    function update(bytes32 marketId) external;
}
