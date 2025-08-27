// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IRewardsCoordinator } from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";

interface IEigenServiceManager {
    /// @dev EigenServiceManager storage
    /// @param accessControl Access control address
    struct EigenServiceManagerStorage {
        address accessControl;
        address allocationManager;
        address delegationManager;
        address strategyManager;
        address rewardsCoordinator;
        address registryCoordinator;
        address stakeRegistry;
        address oracle;
        uint32 rewardDuration;
        uint32 nextOperatorId;
        uint256 minRewardAmount;
        mapping(address => mapping(address => uint256)) lastDistribution;
        mapping(address => address) operatorToStrategy;
        mapping(address => uint32) operatorSetIds;
    }

    /// @notice Initialize the EigenServiceManager
    /// @param _accessControl Access control contract
    /// @param _allocationManager Allocation Manager contract
    /// @param _delegationManager Delegation Manager contract
    /// @param _strategyManager Strategy Manager contract
    /// @param _rewardsCoordinator Rewards Coordinator contract
    /// @param _registryCoordinator Registry Coordinator contract
    /// @param _stakeRegistry Stake Registry contract
    /// @param _oracle Oracle contract
    /// @param _rewardDuration Reward duration
    function initialize(
        address _accessControl,
        address _allocationManager,
        address _delegationManager,
        address _strategyManager,
        address _rewardsCoordinator,
        address _registryCoordinator,
        address _stakeRegistry,
        address _oracle,
        uint32 _rewardDuration
    ) external;

    /**
     * @notice Creates a new rewards submission to the EigenLayer RewardsCoordinator contract, to be split amongst the
     * set of stakers delegated to operators who are registered to this `avs`
     * @param rewardsSubmissions The rewards submissions being created
     * @dev Only callable by the permissioned rewardsInitiator address
     * @dev The duration of the `rewardsSubmission` cannot exceed `MAX_REWARDS_DURATION`
     * @dev The tokens are sent to the `RewardsCoordinator` contract
     * @dev Strategies must be in ascending order of addresses to check for duplicates
     * @dev This function will revert if the `rewardsSubmission` is malformed,
     * e.g. if the `strategies` and `weights` arrays are of non-equal lengths
     * @dev This function may fail to execute with a large number of submissions due to gas limits. Use a
     * smaller array of submissions if necessary.
     */

    /**
     * @notice Distributes rewards to the operator
     * @param _operator The operator to distribute rewards to
     * @param _token The token to distribute rewards for
     */
    function distributeRewards(address _operator, address _token) external;

    /**
     * @notice Returns the coverage for an operator
     * @param operator The operator to get the coverage for
     * @return The coverage of the operator
     */
    function coverage(address operator) external view returns (uint256);

    /**
     * @notice Registers an operator to the AVS
     * @param _operator The operator to register
     * @param _avs The AVS to register the operator to
     * @param _operatorSetIds The operator set ids to register the operator to
     * @param _data Additional data
     */
    function registerOperator(address _operator, address _avs, uint32[] calldata _operatorSetIds, bytes calldata _data)
        external;

    /**
     * @notice Registers a strategy to the AVS
     * @param _strategy The strategy to register
     * @param _operator The operator to register the strategy to
     * @param _metadata The metadata for the strategy
     */
    function registerStrategy(address _strategy, address _operator, string memory _metadata) external;

    /**
     * @notice Slashes an operator
     * @param _operator The operator to slash
     * @param _recipient The recipient of the slashed collateral
     * @param _slashShare The share of the slashable collateral to slash
     * @param _timestamp The timestamp of the slash (unused for eigenlayer)
     */
    function slash(address _operator, address _recipient, uint256 _slashShare, uint48 _timestamp) external;

    /**
     * @notice Returns the slashable collateral for an operator
     * @param operator The operator to get the slashable collateral for
     * @param timestamp The timestamp to get the slashable collateral for (unused for eigenlayer)
     * @return The slashable collateral of the operator
     */
    function slashableCollateral(address operator, uint256 timestamp) external view returns (uint256);

    /**
     * @notice Sets the rewards duration
     * @param _rewardDuration The rewards duration
     */
    function setRewardsDuration(uint32 _rewardDuration) external;

    /**
     * @notice Sets the min reward amount
     * @param _minRewardAmount The min reward amount
     */
    function setMinRewardAmount(uint256 _minRewardAmount) external;
}
