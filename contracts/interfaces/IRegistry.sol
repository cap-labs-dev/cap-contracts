// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IRegistry
/// @author kexley, Cap Labs
/// @notice Interface for deploying and tracking protocol instances
interface IRegistry {
    struct Storage {
        address vault;
        address stablecoin;
        address stakedStablecoin;
        address oracle;
        address irm;
        address marketFactory;
        address trancheFactory;
        address underwriterFactory;
        EnumerableSet.AddressSet markets;
        EnumerableSet.AddressSet tranches;
        EnumerableSet.AddressSet underwriters;
        mapping(address => uint256) multiplier;
    }

    event CreateMarket(
        address market, address asset, string name, uint64 managerId, address seniorTranche, address juniorTranche
    );
    event CreateUnderwriter(address underwriter, address asset, string name, string symbol, uint64 managerId);

    function initialize(
        address authority,
        address stablecoin,
        address stakedStablecoin,
        address vault,
        address oracle,
        address irm,
        address marketFactory,
        address trancheFactory,
        address underwriterFactory
    ) external;

    function createMarket(address asset, string memory name, uint64 managerId, uint64 borrowerId)
        external
        returns (address market, address seniorTranche, address juniorTranche);

    function createUnderwriter(address asset, string memory name, string memory symbol, uint64 managerId)
        external
        returns (address underwriter);

    function setMultiplier(address asset, uint256 multiplier) external;

    function multiplier(address asset) external view returns (uint256);
    function irm() external view returns (address);
    function stablecoin() external view returns (address);
    function stakedStablecoin() external view returns (address);
    function vault() external view returns (address);
    function oracle() external view returns (address);
    function marketFactory() external view returns (address);
    function trancheFactory() external view returns (address);
    function underwriterFactory() external view returns (address);

    function isMarket(address market) external view returns (bool);
    function markets(uint256 start, uint256 end) external view returns (address[] memory);
    function marketsLength() external view returns (uint256);

    function isTranche(address tranche) external view returns (bool);
    function tranches(uint256 start, uint256 end) external view returns (address[] memory);
    function tranchesLength() external view returns (uint256);

    function isUnderwriter(address underwriter) external view returns (bool);
    function underwriters(uint256 start, uint256 end) external view returns (address[] memory);
    function underwritersLength() external view returns (uint256);
}
