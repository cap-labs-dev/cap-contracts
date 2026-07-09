// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IStablecoin
/// @author kexley, Cap Labs
/// @notice Interface for Stablecoin vault accounting
interface IStablecoin {
    struct Storage {
        address irm;
        uint8 underlyingDecimals;
        uint256 unbacked;
        uint256 badDebt;
    }

    event MintUnbacked(address indexed to, uint256 amount);
    event BurnUnbacked(address indexed from, uint256 amount);
    event BadDebtIncreased(uint256 amount);
    event BadDebtReduced(address indexed owner, uint256 amount);

    function badDebt() external view returns (uint256 debt);
    function utilizationRate() external view returns (uint256 rate);
    function mintUnbacked(address _to, uint256 _amount) external;
    function burnUnbacked(address _from, uint256 _amount) external;
    function increaseBadDebt(uint256 _badDebt) external;
}
