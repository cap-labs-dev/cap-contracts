// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";
import { IAllocationManager } from "./interfaces/IAllocationManager.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { IStrategyManager } from "./interfaces/IStrategyManager.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EigenServiceManager
/// @author weso, Cap Labs
/// @notice This contract manages the EigenServiceManager
contract EigenServiceManager is IEigenServiceManager, UUPSUpgradeable, Access, EigenServiceManagerStorageUtils {
    using SafeERC20 for IERC20;

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
    /// @dev Rewards not ready
    error RewardsNotReady();
    /// @dev Operator set already created
    error OperatorSetAlreadyCreated();
    /// @dev Min reward amount not met
    error MinRewardAmountNotMet();

    /// @dev Operator registered
    event OperatorRegistered(address indexed operator, address indexed avs, uint32[] operatorSetIds);
    /// @dev Emitted on slash
    event Slash(address indexed agent, address indexed recipient, uint256 slashShare, uint48 timestamp);
    /// @dev Strategy registered
    event StrategyRegistered(address indexed strategy, address indexed operator);
    /// @dev Rewards duration set
    event RewardsDurationSet(uint32 rewardDuration);
    /// @dev Min reward amount set
    event MinRewardAmountSet(uint256 minRewardAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenServiceManager
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
    ) external initializer {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.allocationManager = _allocationManager;
        $.delegationManager = _delegationManager;
        $.strategyManager = _strategyManager;
        $.rewardsCoordinator = _rewardsCoordinator;
        $.registryCoordinator = _registryCoordinator;
        $.stakeRegistry = _stakeRegistry;
        $.oracle = _oracle;
        $.rewardDuration = _rewardDuration;
        $.nextOperatorId++;

        string memory metadata = string(
            abi.encodePacked(
                '{"name": "cap",',
                '"website": "https://cap.app/",',
                '"description": "Stablecoin protocol with credible financial guarantees",',
                '"logo": "https://cap.app/media-kit/cap_n_y.svg",',
                '"twitter": "https://x.com/capmoney_"}'
            )
        );

        IAllocationManager($.allocationManager).updateAVSMetadataURI(address(this), metadata);
    }

    /// @inheritdoc IEigenServiceManager
    function updateAVSMetadataURI(string memory _metadataURI)
        external
        checkAccess(this.updateAVSMetadataURI.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IAllocationManager($.allocationManager).updateAVSMetadataURI(address(this), _metadataURI);
    }

    /// @inheritdoc IEigenServiceManager
    function slash(address _operator, address _recipient, uint256 _slashShare, uint48)
        external
        checkAccess(this.slash.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[_operator] == address(0)) revert ZeroAddress();

        address _strategy = $.operatorToStrategy[_operator];
        IERC20 _slashedCollateral = IStrategy(_strategy).underlyingToken();

        /// this is a share of the collateral so need to make sure sending correct amount.
        _slash(_strategy, _operator, _slashShare);
        uint256 slashedAmount = _slashedCollateral.balanceOf(address(this));
        _slashedCollateral.safeTransfer(_recipient, slashedAmount);

        emit Slash(_operator, _recipient, slashedAmount, uint48(block.timestamp));
    }

    /// @inheritdoc IEigenServiceManager
    function distributeRewards(address _operator, address _token)
        external
        checkAccess(this.distributeRewards.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        _checkApproval(_token, $.rewardsCoordinator);
        if ($.lastDistribution[_operator][_token] + $.rewardDuration > block.timestamp) revert RewardsNotReady();
        uint256 _amount = IERC20(_token).balanceOf(address(this));
        if (_amount < $.minRewardAmount) revert MinRewardAmountNotMet();
        address _strategy = $.operatorToStrategy[_operator];

        IRewardsCoordinator.RewardsSubmission[] memory rewardsSubmissions =
            new IRewardsCoordinator.RewardsSubmission[](1);
        IRewardsCoordinator.StrategyAndMultiplier[] memory _strategiesAndMultipliers =
            new IRewardsCoordinator.StrategyAndMultiplier[](1);
        _strategiesAndMultipliers[0] =
            IRewardsCoordinator.StrategyAndMultiplier({ strategy: _strategy, multiplier: 1e18 });

        rewardsSubmissions[0] = IRewardsCoordinator.RewardsSubmission({
            strategiesAndMultipliers: _strategiesAndMultipliers,
            token: _token,
            amount: _amount,
            startTimestamp: uint32(block.timestamp),
            duration: $.rewardDuration
        });

        _createAVSRewardsSubmission(rewardsSubmissions);
    }

    /// @inheritdoc IEigenServiceManager
    function registerOperator(address _operator, address _avs, uint32[] calldata _operatorSetIds, bytes calldata)
        external
        checkAccess(this.registerOperator.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[_operator] != address(0)) revert AlreadyRegisteredOperator();
        if (_avs != address(this)) revert InvalidAVS();
        if (_operatorSetIds.length != 1) revert InvalidOperatorSetIds();

        IAllocationManager allocationManager = IAllocationManager($.allocationManager);
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: _avs, id: _operatorSetIds[0] });
        address redistributionRecipient = allocationManager.getRedistributionRecipient(operatorSet);
        if (redistributionRecipient != address(this)) revert InvalidRedistributionRecipient();
        $.operatorSetIds[_operator] = _operatorSetIds[0];
    }

    /// @inheritdoc IEigenServiceManager
    function registerStrategy(address _strategy, address _operator)
        external
        checkAccess(this.registerStrategy.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();

        // Checks
        if ($.operatorToStrategy[_operator] != address(0)) revert AlreadyRegisteredOperator();
        if ($.operatorSetIds[_operator] != 0) revert OperatorSetAlreadyCreated();

        IAllocationManager allocationManager = IAllocationManager($.allocationManager);

        // Create the operator set params
        IAllocationManager.CreateSetParams[] memory params = new IAllocationManager.CreateSetParams[](1);
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;
        params[0] = IAllocationManager.CreateSetParams({ operatorSetId: $.nextOperatorId, strategies: strategies });

        // Create the redistribution recipients
        address[] memory redistributionRecipients = new address[](1);
        redistributionRecipients[0] = address(this);

        // Create the operator set
        allocationManager.createRedistributingOperatorSets(address(this), params, redistributionRecipients);
        $.operatorToStrategy[_operator] = _strategy;
        $.operatorSetIds[_operator] = $.nextOperatorId;
        $.nextOperatorId++;

        emit StrategyRegistered(_strategy, _operator);
    }

    /// @inheritdoc IEigenServiceManager
    function setRewardsDuration(uint32 _rewardDuration) external checkAccess(this.setRewardsDuration.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        $.rewardDuration = _rewardDuration;

        emit RewardsDurationSet(_rewardDuration);
    }

    /// @inheritdoc IEigenServiceManager
    function setMinRewardAmount(uint256 _minRewardAmount) external checkAccess(this.setMinRewardAmount.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        $.minRewardAmount = _minRewardAmount;

        emit MinRewardAmountSet(_minRewardAmount);
    }

    /// @inheritdoc IEigenServiceManager
    function coverage(address operator) external view returns (uint256 delegation) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address _strategy = $.operatorToStrategy[operator];
        if (_strategy == address(0)) revert ZeroAddress();
        address _oracle = $.oracle;
        (delegation,) = coverageByStrategy(operator, _strategy, _oracle);
    }

    /// @inheritdoc IEigenServiceManager
    function slashableCollateral(address operator, uint256) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[operator] == address(0)) revert ZeroAddress();
        return slashableCollateralByStrategy(operator, $.operatorToStrategy[operator]);
    }

    /// @notice Slash the operator
    /// @param _strategy The strategy address
    /// @param _operator The operator address
    /// @param _slashShare The slash share
    function _slash(address _strategy, address _operator, uint256 _slashShare) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        uint256[] memory wadsToSlash = new uint256[](1);
        wadsToSlash[0] = _slashShare;

        IAllocationManager.SlashingParams memory slashingParams = IAllocationManager.SlashingParams({
            operator: _operator,
            operatorSetId: $.operatorSetIds[_operator],
            strategies: strategies,
            wadsToSlash: wadsToSlash,
            description: "liquidation"
        });

        (uint256 slashId,) = IAllocationManager($.allocationManager).slashOperator(address(this), slashingParams);

        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: $.operatorSetIds[_operator] });

        IStrategyManager($.strategyManager).clearBurnOrRedistributableSharesByStrategy(operatorSet, slashId, _strategy);
    }

    /// @notice Create a rewards submission for the AVS
    /// @param rewardsSubmissions The rewards submissions being created
    function _createAVSRewardsSubmission(IRewardsCoordinator.RewardsSubmission[] memory rewardsSubmissions) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IRewardsCoordinator($.rewardsCoordinator).createAVSRewardsSubmission(rewardsSubmissions);
    }

    /// @notice Check if the token has enough allowance for the spender
    /// @param token The token to check
    /// @param spender The spender to check
    function _checkApproval(address token, address spender) private {
        if (IERC20(token).allowance(spender, address(this)) == 0) {
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }

    /// @notice Get the slashable collateral for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The slashable collateral
    function slashableCollateralByStrategy(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address collateralAddress = address(IStrategy(_strategy).underlyingToken());
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        (uint256 collateralPrice,) = IOracle($.oracle).getPrice(collateralAddress);

        uint256 collateral = _getSlashableShares(_operator);
        uint256 collateralValue = collateral * collateralPrice / (10 ** decimals);

        return collateralValue;
    }

    /// @notice Get the coverage for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @param _oracle The oracle address
    /// @return collateralValue The collateral value
    /// @return collateral The collateral
    function coverageByStrategy(address _operator, address _strategy, address _oracle)
        private
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        address collateralAddress = address(IStrategy(_strategy).underlyingToken());
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        (uint256 collateralPrice,) = IOracle(_oracle).getPrice(collateralAddress);

        collateral = _minimumSlashableStake(_operator, _strategy);
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    /// @notice Get the slashable shares for a given operator and strategy
    /// @param operator The operator address
    /// @return The slashable shares of the operator
    function _getSlashableShares(address operator) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address _strategy = $.operatorToStrategy[operator];
        // Get the slashable shares for the operator/OperatorSet
        uint256 slashableShares = _minimumSlashableStake(operator, _strategy);
        // Get the shares in queue
        uint256 sharesInQueue = _slashableSharesInQueue(operator, _strategy);
        // Sum up the slashable shares and the shares in queue
        uint256 totalSlashableShares = slashableShares + sharesInQueue;

        return totalSlashableShares;
    }

    /// @notice Get the slashable shares in queue for withdrawal from a given operator and strategy
    /// @param operator The operator address
    /// @param strategy The strategy address
    /// @return The slashable shares in queue for withdrawal
    function _slashableSharesInQueue(address operator, address strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return IDelegationManager($.delegationManager).getSlashableSharesInQueue(operator, strategy);
    }

    /// @notice Get the minimum slashable stake for a given operator and strategy
    /// @param operator The operator address
    /// @param strategy The strategy address
    /// @return The minimum slashable stake
    function _minimumSlashableStake(address operator, address strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: $.operatorSetIds[operator] });
        address[] memory operators = new address[](1);
        operators[0] = operator;
        address[] memory strategies = new address[](1);
        strategies[0] = strategy;
        uint256[][] memory slashableShares = IAllocationManager($.allocationManager).getMinimumSlashableStake(
            operatorSet, operators, strategies, uint32(block.number)
        );
        return slashableShares[0][0];
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
