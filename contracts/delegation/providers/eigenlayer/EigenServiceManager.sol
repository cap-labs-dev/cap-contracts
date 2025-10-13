// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";
import { EigenOperator, IEigenOperator } from "./EigenOperator.sol";
import { IAllocationManager } from "./interfaces/IAllocationManager.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { IStrategyManager } from "./interfaces/IStrategyManager.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EigenServiceManager
/// @author weso, Cap Labs
/// @notice This contract acts as the avs in the eigenlayer protocol
contract EigenServiceManager is IEigenServiceManager, UUPSUpgradeable, Access, EigenServiceManagerStorageUtils {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenServiceManager
    function initialize(
        address _accessControl,
        EigenAddresses memory _eigenAddresses,
        address _oracle,
        uint32 _epochsBetweenDistributions
    ) external initializer {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.eigen = _eigenAddresses;
        $.oracle = _oracle;
        $.epochsBetweenDistributions = _epochsBetweenDistributions;
        $.nextOperatorId++;
        $.redistributionRecipients.push(address(this));

        // Deploy a instance for the upgradeable beacon proxies
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new EigenOperator()), address(this));
        $.eigenOperatorInstance = address(beacon);

        // Starting metadata for the avs, can be updated later and should be updated when adding new operators
        string memory metadata = "https://cap.app/meta/eigen-avs.json";

        _updateAVSMetadataURI(metadata);
    }

    /// @inheritdoc IEigenServiceManager
    function slash(address _operator, address _recipient, uint256 _slashShare, uint48)
        external
        checkAccess(this.slash.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        if (operatorData.strategy == address(0)) revert ZeroAddress();
        if (_recipient == address(0)) revert ZeroAddress();
        if (_slashShare == 0) revert ZeroSlash();

        address _strategy = operatorData.strategy;
        IERC20 _slashedCollateral = IStrategy(_strategy).underlyingToken();

        /// Slash share is a percentage of total operators collateral, this is calculated in Delegation.sol
        uint256 beforeSlash = _slashedCollateral.balanceOf(address(this));

        /// We map to the eigen operator address in this _slash function
        /// @dev rounding considerations suggested via eigen
        /// https://docs.eigencloud.xyz/products/eigenlayer/developers/howto/build/slashing/precision-rounding-considerations
        /// Since we control the magnitude and are the only allocation, rounding is less of a concern
        _slash(_strategy, _operator, _slashShare);

        /// Send slashed collateral to the liquidator
        uint256 slashedAmount = _slashedCollateral.balanceOf(address(this)) - beforeSlash;
        if (slashedAmount == 0) revert ZeroSlash();
        _slashedCollateral.safeTransfer(_recipient, slashedAmount);

        emit Slash(_operator, _recipient, slashedAmount, uint48(block.timestamp));
    }

    /// @inheritdoc IEigenServiceManager
    function distributeRewards(address _operator, address _token)
        external
        checkAccess(this.distributeRewards.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];

        uint256 calcIntervalSeconds = IRewardsCoordinator($.eigen.rewardsCoordinator).CALCULATION_INTERVAL_SECONDS();
        uint32 lastDistroEpoch = operatorData.lastDistributionEpoch[_token];

        /// Fetch the strategy for the operator
        address _strategy = operatorData.strategy;

        /// Check if rewards are ready - calculate available amount correctly
        uint256 _amount = IERC20(_token).balanceOf(address(this)) - $.pendingRewardsByToken[_token];

        /// If this is the first distribution, use operator creation epoch
        if (lastDistroEpoch == 0) lastDistroEpoch = operatorData.createdAtEpoch;

        /// Calculate the current epoch and check if enough time has passed
        uint32 currentEpoch = uint32(block.timestamp / calcIntervalSeconds);
        uint32 nextAllowedEpoch = lastDistroEpoch + $.epochsBetweenDistributions;

        /// If not enough time has passed since last distribution, add to pending rewards
        if (currentEpoch < nextAllowedEpoch) {
            /// Only add to pending if there are new tokens available
            if (_amount > 0) {
                $.pendingRewardsByToken[_token] += _amount;
                operatorData.pendingRewards[_token] += _amount;
            }
            return;
        }

        /// Include both new tokens and any existing pending rewards for this operator
        uint256 totalAmount = _amount + operatorData.pendingRewards[_token];

        /// Only proceed if there are rewards to distribute
        if (totalAmount == 0) return;

        _checkApproval(_token, $.eigen.rewardsCoordinator);
        _createRewardsSubmission(_operator, _strategy, _token, totalAmount, lastDistroEpoch, currentEpoch);

        /// Update accounting: subtract the pending rewards that were just distributed
        $.pendingRewardsByToken[_token] -= operatorData.pendingRewards[_token];
        operatorData.pendingRewards[_token] = 0;
        operatorData.lastDistributionEpoch[_token] = currentEpoch;

        emit DistributedRewards(_operator, _token, totalAmount);
    }

    /// @inheritdoc IEigenServiceManager
    function registerOperator(address _eigenOperator, address _avs, uint32[] calldata _operatorSetIds, bytes calldata)
        external
        checkAccess(this.registerOperator.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if (_avs != address(this)) revert InvalidAVS();
        if (_operatorSetIds.length != 1) revert InvalidOperatorSetIds();

        IAllocationManager allocationManager = IAllocationManager($.eigen.allocationManager);
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: _avs, id: _operatorSetIds[0] });

        address redistributionRecipient = allocationManager.getRedistributionRecipient(operatorSet);
        if (redistributionRecipient != address(this)) revert InvalidRedistributionRecipient();

        emit OperatorRegistered(IEigenOperator(_eigenOperator).operator(), _eigenOperator, _avs, _operatorSetIds[0]);
    }

    /// @inheritdoc IEigenServiceManager
    function registerStrategy(address _strategy, address _operator, address _restaker, string memory _operatorMetadata)
        external
        checkAccess(this.registerStrategy.selector)
        returns (uint32 _operatorSetId)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];

        // Deploy the operator clone that will act as the operator in the eigen system
        address eigenOperator = _deployEigenOperator(_operator, _operatorMetadata);
        operatorData.eigenOperator = eigenOperator;
        _operatorSetId = $.nextOperatorId;

        // Checks, no duplicate operators or operator set ids, a strategy can have many operators.
        // Since restakers can only delegate to one operator, this is not a problem.
        // https://docs.eigencloud.xyz/products/eigenlayer/restakers/restaking-guides/restaking-developer-guide#smart-contract-delegation-user-guide
        if (operatorData.strategy != address(0)) revert AlreadyRegisteredOperator();
        if (operatorData.operatorSetId != 0) revert OperatorSetAlreadyCreated();
        if (IERC20Metadata(address(IStrategy(_strategy).underlyingToken())).decimals() < 6) revert InvalidDecimals();

        IAllocationManager allocationManager = IAllocationManager($.eigen.allocationManager);

        // Create the operator set params
        IAllocationManager.CreateSetParams[] memory params = new IAllocationManager.CreateSetParams[](1);
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        params[0] = IAllocationManager.CreateSetParams({ operatorSetId: _operatorSetId, strategies: strategies });

        // Create the operator set
        allocationManager.createRedistributingOperatorSets(address(this), params, $.redistributionRecipients);
        operatorData.strategy = _strategy;
        operatorData.operatorSetId = _operatorSetId;

        uint256 calcIntervalSeconds = IRewardsCoordinator($.eigen.rewardsCoordinator).CALCULATION_INTERVAL_SECONDS();
        operatorData.createdAtEpoch = uint32(block.timestamp / calcIntervalSeconds);

        // Callback the operator beacon and register to the operator set
        EigenOperator(eigenOperator).registerOperatorSetToServiceManager(_operatorSetId, _restaker);

        // Increment the next operator id for the next operator set
        $.nextOperatorId++;
        emit StrategyRegistered(_strategy, _operator);
    }

    /// @inheritdoc IEigenServiceManager
    function updateAVSMetadataURI(string calldata _metadataURI)
        external
        checkAccess(this.updateAVSMetadataURI.selector)
    {
        _updateAVSMetadataURI(_metadataURI);
    }

    /// @inheritdoc IEigenServiceManager
    function setEpochsBetweenDistributions(uint32 _epochsBetweenDistributions)
        external
        checkAccess(this.setEpochsBetweenDistributions.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        $.epochsBetweenDistributions = _epochsBetweenDistributions;

        emit EpochsBetweenDistributionsSet(_epochsBetweenDistributions);
    }

    /// @inheritdoc IEigenServiceManager
    function allocate(address _operator) external {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        if (operatorData.eigenOperator == address(0)) revert ZeroAddress();

        EigenOperator(operatorData.eigenOperator).allocate(operatorData.operatorSetId, operatorData.strategy);
    }

    /// @inheritdoc IEigenServiceManager
    function upgradeEigenOperatorImplementation(address _newImplementation)
        external
        checkAccess(this.upgradeEigenOperatorImplementation.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if (_newImplementation == address(0)) revert ZeroAddress();

        UpgradeableBeacon beacon = UpgradeableBeacon($.eigenOperatorInstance);
        beacon.upgradeTo(_newImplementation);
    }

    /// @inheritdoc IEigenServiceManager
    function coverage(address _operator) external view returns (uint256 delegation) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        address _strategy = operatorData.strategy;
        if (_strategy == address(0)) return 0;

        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        /// Reject small shares for coverage because of rounding concerns
        uint256[] memory operatorShares =
            IDelegationManager($.eigen.delegationManager).getOperatorShares(operatorData.eigenOperator, strategies);
        if (operatorShares[0] < 1e9) return 0;

        address _oracle = $.oracle;
        (delegation,) = _coverageByStrategy(_operator, _strategy, _oracle);
    }

    /// @inheritdoc IEigenServiceManager
    function getEigenOperator(address _operator) external view returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.operators[_operator].eigenOperator;
    }

    /// @inheritdoc IEigenServiceManager
    function slashableCollateral(address _operator, uint48) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        if (operatorData.strategy == address(0)) return 0;
        return _slashableCollateralByStrategy(_operator, operatorData.strategy);
    }

    /// @inheritdoc IEigenServiceManager
    function operatorSetId(address _operator) external view returns (uint32) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        return operatorData.operatorSetId;
    }

    /// @inheritdoc IEigenServiceManager
    function operatorToStrategy(address _operator) external view returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        return operatorData.strategy;
    }

    /// @inheritdoc IEigenServiceManager
    function eigenAddresses() external view returns (EigenAddresses memory) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.eigen;
    }

    /// @inheritdoc IEigenServiceManager
    function epochsBetweenDistributions() external view returns (uint32) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.epochsBetweenDistributions;
    }

    /// @inheritdoc IEigenServiceManager
    function pendingRewards(address _operator, address _token) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        return operatorData.pendingRewards[_token];
    }

    /// @dev Deploys an eigen operator
    /// @param _operator The operator/borrower address
    /// @param _operatorMetadata The operator metadata
    /// @return _eigenOperator The eigen operator contract address
    function _deployEigenOperator(address _operator, string memory _operatorMetadata)
        private
        returns (address _eigenOperator)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();

        // Best practice initialize on deployment
        bytes memory initdata =
            abi.encodeWithSelector(EigenOperator.initialize.selector, address(this), _operator, _operatorMetadata);
        _eigenOperator = address(new BeaconProxy($.eigenOperatorInstance, initdata));
    }

    /// @notice Updates the metadata URI for the AVS
    /// @param _metadataURI is the metadata URI for the AVS
    function _updateAVSMetadataURI(string memory _metadataURI) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IAllocationManager($.eigen.allocationManager).updateAVSMetadataURI(address(this), _metadataURI);
    }

    /// @notice Slash the operator
    /// @param _strategy The strategy address
    /// @param _operator The operator address
    /// @param _slashShare The slash share
    function _slash(address _strategy, address _operator, uint256 _slashShare) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        _slashShare += 1;
        _slashShare = _slashShare > 1e18 ? 1e18 : _slashShare;

        // @dev wads are a percentage of collateral in 1e18
        uint256[] memory wadsToSlash = new uint256[](1);
        wadsToSlash[0] = _slashShare;

        IAllocationManager.SlashingParams memory slashingParams = IAllocationManager.SlashingParams({
            operator: operatorData.eigenOperator,
            operatorSetId: operatorData.operatorSetId,
            strategies: strategies,
            wadsToSlash: wadsToSlash,
            description: "liquidation"
        });

        // @dev slash the operator
        (uint256 slashId,) = IAllocationManager($.eigen.allocationManager).slashOperator(address(this), slashingParams);

        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: operatorData.operatorSetId });

        // @dev clear the burn or redistributable shares, this sends them to the service manager
        IStrategyManager($.eigen.strategyManager).clearBurnOrRedistributableSharesByStrategy(
            operatorSet, slashId, _strategy
        );
    }

    /// @notice Create a rewards submission
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @param _token The token address
    /// @param _amount The amount of tokens (already includes pending rewards)
    /// @param _lastDistroEpoch The last distribution epoch
    /// @param _currentEpoch The current epoch
    function _createRewardsSubmission(
        address _operator,
        address _strategy,
        address _token,
        uint256 _amount,
        uint256 _lastDistroEpoch,
        uint256 _currentEpoch
    ) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];

        /// Get the strategy for the operator and create the rewards submission
        IRewardsCoordinator.OperatorDirectedRewardsSubmission[] memory rewardsSubmissions =
            new IRewardsCoordinator.OperatorDirectedRewardsSubmission[](1);
        IRewardsCoordinator.StrategyAndMultiplier[] memory _strategiesAndMultipliers =
            new IRewardsCoordinator.StrategyAndMultiplier[](1);

        IRewardsCoordinator.OperatorReward[] memory _operatorRewards = new IRewardsCoordinator.OperatorReward[](1);
        _operatorRewards[0] =
            IRewardsCoordinator.OperatorReward({ operator: operatorData.eigenOperator, amount: _amount });

        IRewardsCoordinator.OperatorSet memory operatorSet =
            IRewardsCoordinator.OperatorSet({ avs: address(this), id: operatorData.operatorSetId });

        /// Since there is only 1 strategy multiplier is just 1e18 everything goes to the strategy
        _strategiesAndMultipliers[0] =
            IRewardsCoordinator.StrategyAndMultiplier({ strategy: _strategy, multiplier: 1e18 });

        uint256 calcIntervalSeconds = IRewardsCoordinator($.eigen.rewardsCoordinator).CALCULATION_INTERVAL_SECONDS();

        // Start at the next epoch to next double reward the current epoch which should have been included in the previous distribution
        _lastDistroEpoch += 1;
        uint48 maxDuration = IRewardsCoordinator($.eigen.rewardsCoordinator).MAX_REWARDS_DURATION();
        uint256 startTimestamp = _lastDistroEpoch * calcIntervalSeconds;
        uint256 duration = (_currentEpoch - _lastDistroEpoch) * calcIntervalSeconds;
        if (duration > maxDuration) duration = maxDuration;

        rewardsSubmissions[0] = IRewardsCoordinator.OperatorDirectedRewardsSubmission({
            strategiesAndMultipliers: _strategiesAndMultipliers,
            token: _token,
            operatorRewards: _operatorRewards,
            startTimestamp: uint32(startTimestamp),
            duration: uint32(duration),
            description: "interest"
        });

        IRewardsCoordinator($.eigen.rewardsCoordinator).createOperatorDirectedOperatorSetRewardsSubmission(
            operatorSet, rewardsSubmissions
        );
    }

    /// @notice Check if the token has enough allowance for the spender
    /// @param _token The token to check
    /// @param _spender The spender to check
    function _checkApproval(address _token, address _spender) private {
        if (IERC20(_token).allowance(_spender, address(this)) == 0) {
            IERC20(_token).forceApprove(_spender, type(uint256).max);
        }
    }

    /// @notice Get the slashable collateral for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The slashable collateral
    function _slashableCollateralByStrategy(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address collateralAddress = address(IStrategy(_strategy).underlyingToken());
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        (uint256 collateralPrice,) = IOracle($.oracle).getPrice(collateralAddress);

        uint256 collateral = _getSlashableStake(_operator);
        uint256 collateralValue = collateral * collateralPrice / (10 ** decimals);

        return collateralValue;
    }

    /// @notice Get the coverage for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @param _oracle The oracle address
    /// @return collateralValue The collateral value
    /// @return collateral The collateral
    function _coverageByStrategy(address _operator, address _strategy, address _oracle)
        private
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        address collateralAddress = address(IStrategy(_strategy).underlyingToken());
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        (uint256 collateralPrice,) = IOracle(_oracle).getPrice(collateralAddress);

        // @dev get the minimum slashable stake
        collateral = _minimumSlashableStake(_operator, _strategy);
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    /// @notice Get the slashable stake for a given operator and strategy
    /// @param _operator The operator address
    /// @return The slashable stake of the operator
    function _getSlashableStake(address _operator) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];

        address _strategy = operatorData.strategy;
        // Get the slashable stake for the operator/OperatorSet
        uint256 slashableStake = _minimumSlashableStake(_operator, _strategy);
        // Get the stake in queue
        uint256 stakeInQueue = _slashableStakeInQueue(operatorData.eigenOperator, _strategy);
        // Sum up the slashable stake and the stake in queue
        uint256 totalSlashableStake = slashableStake + stakeInQueue;

        return totalSlashableStake;
    }

    /// @notice Get the slashable stake in queue for withdrawal from a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The slashable stake in queue for withdrawal
    function _slashableStakeInQueue(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        // @dev get the slashable stake in queue which are waiting to be withdrawn
        return IStrategy(_strategy).sharesToUnderlyingView(
            IDelegationManager($.eigen.delegationManager).getSlashableSharesInQueue(_operator, _strategy)
        );
    }

    /// @notice Get the minimum slashable stake for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The minimum slashable stake
    function _minimumSlashableStake(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        CachedOperatorData storage operatorData = $.operators[_operator];
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: operatorData.operatorSetId });
        address[] memory operators = new address[](1);
        operators[0] = operatorData.eigenOperator;
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        // @dev get the minimum slashable stake at the current block
        uint256[][] memory slashableShares = IAllocationManager($.eigen.allocationManager).getMinimumSlashableStake(
            operatorSet, operators, strategies, uint32(block.number)
        );
        return IStrategy(_strategy).sharesToUnderlyingView(slashableShares[0][0]);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
