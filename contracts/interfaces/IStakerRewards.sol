// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IStakerRewards
/// @author weso, Cap Labs
/// @notice Interface for the staker rewards contract
interface IStakerRewards {
    /// @dev Emitted when a reward is distributed
    /// @param network Network on behalf of which the reward is distributed
    /// @param token Address of the token
    /// @param amount Amount of tokens
    /// @param data Some used data
    event DistributeRewards(address indexed network, address indexed token, uint256 amount, bytes data);

    /// @notice Distribute rewards on behalf of a particular network using a given token
    /// @param network Network on behalf of which the reward to distribute
    /// @param token Address of the token
    /// @param amount Amount of tokens
    /// @param data Some used data
    function distributeRewards(address network, address token, uint256 amount, bytes calldata data) external;

    /// @notice Claim rewards using a given token
    /// @param recipient Address of the tokens' recipient
    /// @param token Address of the token
    /// @param data Some used data
    function claimRewards(address recipient, address token, bytes calldata data) external;

    /// @notice Get a version of the staker rewards contract (different versions mean different interfaces)
    /// @dev Must return 1 for this one
    /// @return version of the staker rewards contract
    function version() external view returns (uint64);

    /// @notice Get an amount of rewards claimable by a particular account of a given token
    /// @param token Address of the token
    /// @param account Address of the claimer
    /// @param data Some used data
    /// @return amount Amount of claimable tokens
    function claimable(address token, address account, bytes calldata data) external view returns (uint256);
}
