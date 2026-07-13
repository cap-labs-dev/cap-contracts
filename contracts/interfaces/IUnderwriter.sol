// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IUnderwriter
/// @author kexley, Cap Labs
/// @notice Interface for Underwriter contract
interface IUnderwriter is IERC7540AsyncRedeem {
    error InvalidTranche();
    error InvalidVestingPeriod();

    struct Storage {
        address vault;
        address registry;
        address stablecoin;
        EnumerableSet.AddressSet whitelist;
        mapping(address => uint256) debt;
        uint256 totalDebt;
        uint256 vestedReward;
        uint256 rewardPerSecond;
        uint256 vestingPeriod;
        uint256 lastReported;
        mapping(address => uint256) pendingReward;
        mapping(address => uint256) rewardDebt;
        uint256 lastRewardUpdate;
        uint256 rewardPerShare;
        address defaultTranche;
    }

    event DebtIncreased(address indexed tranche, uint256 amount);
    event DebtDecreased(address indexed tranche, uint256 amount);
    event RequestedRedeem(address indexed tranche, uint256 shares, uint256 requestId);
    event Reported(address indexed tranche, uint256 reward, uint256 gain, uint256 loss);
    event SetDefaultTranche(address tranche);
    event SetVestingPeriod(uint256 vestingPeriod);

    /// @notice Initialize the underwriter
    /// @param name The name of the underwriter
    /// @param symbol The symbol of the underwriter
    /// @param asset The asset of the underwriter
    function initialize(address authority, string memory name, string memory symbol, address asset) external;

    /// @notice Allocate assets to a tranche
    /// @param tranche The tranche to allocate to
    /// @param assets The assets to allocate
    function allocate(address tranche, uint256 assets) external;

    /// @notice Set the default tranche
    /// @param tranche The default tranche
    function setDefaultTranche(address tranche) external;

    /// @notice Whitelist an account
    /// @param account The account to whitelist
    /// @param allowed Whether the account is whitelisted
    function whitelist(address account, bool allowed) external;

    /// @notice Get the vault
    /// @return vault The vault
    function vault() external view returns (address);

    /// @notice Get the registry
    /// @return registry The registry
    function registry() external view returns (address);

    /// @notice Get the stablecoin
    /// @return stablecoin The stablecoin
    function stablecoin() external view returns (address);

    /// @notice Deallocate assets from a tranche asynchronously
    /// @param tranche The tranche to deallocate from
    /// @param shares The shares to deallocate
    /// @return requestId The request ID
    function deallocateAsync(address tranche, uint256 shares) external returns (uint256 requestId);

    /// @notice Deallocate assets from a tranche
    /// @param tranche The tranche to deallocate from

    /// @notice Instantly deallocate unlocked shares from a tranche
    /// @param tranche The tranche to deallocate from
    /// @param shares The shares to deallocate
    /// @return deallocated The amount of shares deallocated
    function deallocate(address tranche, uint256 shares) external returns (uint256 deallocated);

    /// @notice Finalize a deallocate request asynchronously
    /// @param tranche The tranche to finalize the deallocate request for
    /// @param requestId The request ID
    /// @param shares The shares to finalize the deallocate request for

    /// @notice Finalize an async deallocation using a request id
    /// @param tranche The tranche to deallocate from
    /// @param requestId The request id
    /// @param shares The shares to deallocate
    function finalizeDeallocateAsync(address tranche, uint256 requestId, uint256 shares) external;

    /// @notice Report the debt and rewards for a tranche
    /// @param tranche The tranche to report
    function report(address tranche) external;

    /// @notice Set the vesting period
    /// @param vestingPeriod The vesting period
    function setVestingPeriod(uint256 vestingPeriod) external;

    /// @notice Claim the reward for the caller
    function claim() external;

    /// @notice Get the claimable reward for a user
    /// @param user The user to get the claimable reward for
    /// @return reward The claimable reward
    function claimable(address user) external view returns (uint256 reward);

    /// @notice Get the vested reward
    /// @return vested The vested reward
    function vestedReward() external view returns (uint256 vested);

    /// @notice Get the vesting end
    /// @return end The vesting end
    function vestingEnd() external view returns (uint256 end);

    /// @notice Check if an account is whitelisted
    /// @param account The account to check
    /// @return allowed Whether the account is whitelisted
    function whitelisted(address account) external view returns (bool allowed);
}
