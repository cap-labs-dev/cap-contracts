// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IRewardsCoordinator } from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";

interface IEigenServiceManager {
    /// @dev Invalid AVS
    error InvalidAVS();
    /// @dev Invalid operator set ids
    error InvalidOperatorSetIds();
    /// @dev Invalid operator
    error InvalidOperator();
    /// @dev Operator already registered
    error AlreadyRegisteredOperator();
    /// @dev Invalid redistribution recipient
    error InvalidRedistributionRecipient();
    /// @dev Zero address
    error ZeroAddress();
    /// @dev Operator set already created
    error OperatorSetAlreadyCreated();
    /// @dev Min magnitude not met
    error MinMagnitudeNotMet();
    /// @dev Invalid decimals
    error InvalidDecimals();
    /// @dev Min share not met
    error MinShareNotMet();
    /// @dev Zero slash
    error ZeroSlash();
    /// @dev Slash share too small
    error SlashShareTooSmall();

    /// @dev Operator registered
    event OperatorRegistered(address indexed operator, address indexed avs, uint32 operatorSetId);
    /// @dev Emitted on slash
    event Slash(address indexed agent, address indexed recipient, uint256 slashShare, uint48 timestamp);
    /// @dev Strategy registered
    event StrategyRegistered(address indexed strategy, address indexed operator);
    /// @dev Rewards duration set
    event RewardsDurationSet(uint32 rewardDuration);
    /// @dev Min reward amount set
    event MinRewardAmountSet(uint256 minRewardAmount);
    /// @dev Distributed rewards
    event DistributedRewards(address indexed strategy, address indexed token, uint256 amount);

    /// @dev EigenServiceManager storage
    /// @param accessControl Access control address
    /// @param eigen Eigen addresses
    /// @param oracle Oracle address
    /// @param rewardDuration Reward duration
    /// @param nextOperatorId Next operator id
    /// @param minRewardAmount Min reward amount
    /// @param pendingRewards Pending rewards
    /// @param lastDistribution Last distribution
    struct EigenServiceManagerStorage {
        EigenAddresses eigen;
        address accessControl;
        address oracle;
        uint32 rewardDuration;
        uint32 nextOperatorId;
        uint256 minRewardAmount;
        mapping(address => mapping(address => uint256)) pendingRewards;
        mapping(address => mapping(address => uint32)) lastDistribution;
        mapping(address => address) operatorToStrategy;
        mapping(address => uint32) operatorSetIds;
    }

    /// @dev Eigen addresses
    /// @param allocationManager Allocation manager address
    /// @param delegationManager Delegation manager address
    /// @param strategyManager Strategy manager address
    /// @param rewardsCoordinator Rewards coordinator address
    struct EigenAddresses {
        address allocationManager;
        address delegationManager;
        address strategyManager;
        address rewardsCoordinator;
    }

    /// @notice Initialize the EigenServiceManager
    /// @param _accessControl Access control contract
    /// @param _addresses Eigen addresses
    /// @param _oracle Oracle contract
    /// @param _rewardDuration Reward duration
    function initialize(
        address _accessControl,
        EigenAddresses memory _addresses,
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
     * @return _operatorSetId The operator set id
     */
    function registerStrategy(address _strategy, address _operator, string memory _metadata)
        external
        returns (uint256 _operatorSetId);

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

    /**
     * @notice Returns the eigen addresses
     * @return The eigen addresses
     */
    function eigenAddresses() external view returns (EigenAddresses memory);

    /**
     * @notice Returns the operator to strategy mapping
     * @return The operator to strategy mapping
     */
    function operatorToStrategy(address operator) external view returns (address);

    /**
     * @notice Returns the operator set id for an operator
     * @param operator The operator to get the operator set id for
     * @return The operator set id of the operator
     */
    function operatorSetId(address operator) external view returns (uint32);

    /**
     * @notice Returns the min reward amount
     * @return The min reward amount
     */
    function minRewardAmount() external view returns (uint256);

    /**
     * @notice Returns the rewards duration
     * @return The rewards duration
     */
    function rewardDuration() external view returns (uint32);

    /**
     * @notice Returns the pending rewards for an operator
     * @param _strategy The strategy to get the pending rewards for
     * @param _token The token to get the pending rewards for
     * @return The pending rewards of the strategy
     */
    function pendingRewards(address _strategy, address _token) external view returns (uint256);
}
