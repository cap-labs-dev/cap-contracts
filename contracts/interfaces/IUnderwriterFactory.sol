// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IUnderwriterFactory
/// @author kexley, Cap Labs
/// @notice Interface for deploying underwriter beacon proxies
interface IUnderwriterFactory {
    struct Storage {
        address beacon;
    }

    event UnderwriterCreated(address indexed underwriter);

    /// @notice Initialize the factory
    /// @param authority The access manager address
    /// @param beacon The underwriter implementation beacon
    function initialize(address authority, address beacon) external;

    /// @notice Deploy a new underwriter
    /// @param authority The access manager address
    /// @param name The underwriter share name
    /// @param symbol The underwriter share symbol
    /// @param asset The collateral asset
    /// @param vault The ERC6909 vault
    /// @param lender The lender address
    /// @param rewardToken The reward token address
    /// @param managerId The access manager role id for curator functions
    /// @return underwriter The deployed underwriter address
    function createUnderwriter(
        address authority,
        string memory name,
        string memory symbol,
        address asset,
        address vault,
        address lender,
        address rewardToken,
        uint64 managerId
    ) external returns (address underwriter);
}
