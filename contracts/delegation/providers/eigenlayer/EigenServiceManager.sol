// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";
import { EigenOperator } from "./EigenOperator.sol";
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
        uint32 _epochDuration
    ) external initializer {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.eigen = _eigenAddresses;
        $.oracle = _oracle;
        $.epochDuration = _epochDuration;
        $.nextOperatorId++;

        // Deploy a instance for the upgradeable beacon proxies
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new EigenOperator()), address(this));
        $.eigenOperatorInstance = address(beacon);

        // Starting metadata for the avs, can be updated later and should be updated when adding new operators
        string memory metadata = string(
            abi.encodePacked(
                '{"name": "cap",',
                '"website": "https://cap.app/",',
                '"description": "Stablecoin protocol with credible financial guarantees",',
                '"logo": "https://cap.app/media-kit/cap_b_y_882%C3%97848.png",',
                '"twitter": "https://x.com/capmoney_"}'
            )
        );

        _updateAVSMetadataURI(metadata);
    }

    /// @inheritdoc IEigenServiceManager
    function slash(address _operator, address _recipient, uint256 _slashShare, uint48)
        external
        checkAccess(this.slash.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[_operator] == address(0)) revert ZeroAddress();
        if (_recipient == address(0)) revert ZeroAddress();
        /// @dev rounding considerations suggested via eigen
        /// https://docs.eigencloud.xyz/products/eigenlayer/developers/howto/build/slashing/precision-rounding-considerations
        if (_slashShare < 1e15) revert SlashShareTooSmall();

        address _strategy = $.operatorToStrategy[_operator];
        IERC20 _slashedCollateral = IStrategy(_strategy).underlyingToken();

        /// Slash share is a percentage of total operators collateral, this is calculated in Delegation.sol
        uint256 beforeSlash = _slashedCollateral.balanceOf(address(this));

        /// We map to the eigen operator address in this _slash function
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

        uint256 calcIntervalSeconds = IRewardsCoordinator($.eigen.rewardsCoordinator).CALCULATION_INTERVAL_SECONDS();

        /// Fetch the strategy for the operator
        address _strategy = $.operatorToStrategy[_operator];

        /// Check if rewards are ready
        uint256 _amount = IERC20(_token).balanceOf(address(this)) - $.pendingRewardsByToken[_token];
        if (
            ($.lastDistributionEpoch[_operator][_token] * calcIntervalSeconds) + ($.epochDuration * calcIntervalSeconds)
                > block.timestamp
        ) {
            $.pendingRewardsByToken[_token] += _amount;
            $.pendingRewards[_operator][_token] += _amount;
            return;
        }

        _checkApproval(_token, $.eigen.rewardsCoordinator);

        /// include pending rewards
        _amount += $.pendingRewards[_operator][_token];

        /// Get the strategy for the operator and create the rewards submission
        IRewardsCoordinator.OperatorDirectedRewardsSubmission[] memory rewardsSubmissions =
            new IRewardsCoordinator.OperatorDirectedRewardsSubmission[](1);
        IRewardsCoordinator.StrategyAndMultiplier[] memory _strategiesAndMultipliers =
            new IRewardsCoordinator.StrategyAndMultiplier[](1);

        IRewardsCoordinator.OperatorReward[] memory _operatorRewards = new IRewardsCoordinator.OperatorReward[](1);
        _operatorRewards[0] =
            IRewardsCoordinator.OperatorReward({ operator: $.operatorToEigenOperator[_operator], amount: _amount });

        IRewardsCoordinator.OperatorSet memory operatorSet =
            IRewardsCoordinator.OperatorSet({ avs: address(this), id: $.operatorSetIds[_operator] });

        /// Since there is only 1 strategy multiplier is just 1e18 everything goes to the strategy
        _strategiesAndMultipliers[0] =
            IRewardsCoordinator.StrategyAndMultiplier({ strategy: _strategy, multiplier: 1e18 });

        uint256 roundedStartEpoch = (block.timestamp / calcIntervalSeconds) - $.epochDuration;
        uint256 startTimestamp = roundedStartEpoch * calcIntervalSeconds;

        rewardsSubmissions[0] = IRewardsCoordinator.OperatorDirectedRewardsSubmission({
            strategiesAndMultipliers: _strategiesAndMultipliers,
            token: _token,
            operatorRewards: _operatorRewards,
            startTimestamp: uint32(startTimestamp),
            duration: uint32($.epochDuration * calcIntervalSeconds),
            description: "interest"
        });

        _createRewardsSubmission(operatorSet, rewardsSubmissions);

        $.pendingRewardsByToken[_token] -= $.pendingRewards[_operator][_token];
        $.pendingRewards[_operator][_token] = 0;
        $.lastDistributionEpoch[_operator][_token] = uint32(block.timestamp) / uint32(calcIntervalSeconds);

        emit DistributedRewards(_operator, _token, _amount);
    }

    /// @inheritdoc IEigenServiceManager
    function registerOperator(address _operator, address _avs, uint32[] calldata _operatorSetIds, bytes calldata)
        external
        checkAccess(this.registerOperator.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if (_avs != address(this)) revert InvalidAVS();
        if (_operatorSetIds.length != 1) revert InvalidOperatorSetIds();

        /// Avoid precision errors
        if (
            IAllocationManager($.eigen.allocationManager).getAllocatableMagnitude(
                _operator, $.operatorToStrategy[_operator]
            ) < 1e9
        ) revert MinMagnitudeNotMet();

        IAllocationManager allocationManager = IAllocationManager($.eigen.allocationManager);
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: _avs, id: _operatorSetIds[0] });
        address redistributionRecipient = allocationManager.getRedistributionRecipient(operatorSet);
        if (redistributionRecipient != address(this)) revert InvalidRedistributionRecipient();
        $.operatorSetIds[_operator] = _operatorSetIds[0];

        emit OperatorRegistered(_operator, _avs, _operatorSetIds[0]);
    }

    /// @inheritdoc IEigenServiceManager
    function registerStrategy(
        address _strategy,
        address _operator,
        address _restaker,
        string memory _avsMetadata,
        string memory _operatorMetadata
    ) external checkAccess(this.registerStrategy.selector) returns (uint32 _operatorSetId) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();

        // Deploy the operator clone that will act as the operator in the eigen system
        address eigenOperator = _deployEigenOperator(_operator, _operatorMetadata);
        $.operatorToEigenOperator[_operator] = eigenOperator;
        _operatorSetId = $.nextOperatorId;

        // Checks, no duplicate operators or operator set ids, a strategy can have many operators.
        // Since restakers can only delegate to one operator, this is not a problem.
        // https://docs.eigencloud.xyz/products/eigenlayer/restakers/restaking-guides/restaking-developer-guide#smart-contract-delegation-user-guide
        if ($.operatorToStrategy[_operator] != address(0)) revert AlreadyRegisteredOperator();
        if ($.operatorSetIds[_operator] != 0) revert OperatorSetAlreadyCreated();
        if (IERC20Metadata(address(IStrategy(_strategy).underlyingToken())).decimals() < 6) revert InvalidDecimals();

        IAllocationManager allocationManager = IAllocationManager($.eigen.allocationManager);

        // Create the operator set params
        IAllocationManager.CreateSetParams[] memory params = new IAllocationManager.CreateSetParams[](1);
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        params[0] = IAllocationManager.CreateSetParams({ operatorSetId: _operatorSetId, strategies: strategies });

        // Create the redistribution recipients
        address[] memory redistributionRecipients = new address[](1);
        redistributionRecipients[0] = address(this);

        // Create the operator set
        allocationManager.createRedistributingOperatorSets(address(this), params, redistributionRecipients);
        $.operatorToStrategy[_operator] = _strategy;
        $.operatorSetIds[_operator] = _operatorSetId;
        _updateAVSMetadataURI(_avsMetadata);

        // Allocate to the strategy
        EigenOperator(eigenOperator).registerOperatorSetToServiceManager(_operatorSetId, _restaker);

        $.nextOperatorId++;
        emit StrategyRegistered(_strategy, _operator);
    }

    /// @inheritdoc IEigenServiceManager
    function setEpochDuration(uint32 _epochDuration) external checkAccess(this.setEpochDuration.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        $.epochDuration = _epochDuration;

        emit EpochDurationSet(_epochDuration);
    }

    /// @inheritdoc IEigenServiceManager
    function allocate(address _operator) external {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        EigenOperator($.operatorToEigenOperator[_operator]).allocate(
            $.operatorSetIds[_operator], $.operatorToStrategy[_operator]
        );
    }

    /// @inheritdoc IEigenServiceManager
    function upgradeEigenOperatorImplementation(address _newImplementation)
        external
        checkAccess(this.upgradeEigenOperatorImplementation.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        UpgradeableBeacon beacon = UpgradeableBeacon($.eigenOperatorInstance);
        beacon.upgradeTo(_newImplementation);
    }

    /// @inheritdoc IEigenServiceManager
    function coverage(address _operator) external view returns (uint256 delegation) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address _strategy = $.operatorToStrategy[_operator];
        if (_strategy == address(0)) return 0;

        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        uint256[] memory operatorShares = IDelegationManager($.eigen.delegationManager).getOperatorShares(
            $.operatorToEigenOperator[_operator], strategies
        );
        if (operatorShares[0] < 1e9) return 0;

        address _oracle = $.oracle;
        (delegation,) = _coverageByStrategy(_operator, _strategy, _oracle);
    }

    /// @inheritdoc IEigenServiceManager
    function getEigenOperator(address _operator) external view returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.operatorToEigenOperator[_operator];
    }

    /// @inheritdoc IEigenServiceManager
    function slashableCollateral(address _operator, uint256) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[_operator] == address(0)) return 0;
        return _slashableCollateralByStrategy(_operator, $.operatorToStrategy[_operator]);
    }

    /// @inheritdoc IEigenServiceManager
    function operatorSetId(address _operator) external view returns (uint32) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.operatorSetIds[_operator];
    }

    /// @inheritdoc IEigenServiceManager
    function operatorToStrategy(address _operator) external view returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.operatorToStrategy[_operator];
    }

    /// @inheritdoc IEigenServiceManager
    function eigenAddresses() external view returns (EigenAddresses memory) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.eigen;
    }

    /// @inheritdoc IEigenServiceManager
    function epochDuration() external view returns (uint32) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.epochDuration;
    }

    /// @inheritdoc IEigenServiceManager
    function pendingRewards(address _operator, address _token) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.pendingRewards[_operator][_token];
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
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        // @dev wads are a percentage of collateral in 1e18
        uint256[] memory wadsToSlash = new uint256[](1);
        wadsToSlash[0] = _slashShare;

        IAllocationManager.SlashingParams memory slashingParams = IAllocationManager.SlashingParams({
            operator: $.operatorToEigenOperator[_operator],
            operatorSetId: $.operatorSetIds[_operator],
            strategies: strategies,
            wadsToSlash: wadsToSlash,
            description: "liquidation"
        });

        // @dev slash the operator
        (uint256 slashId,) = IAllocationManager($.eigen.allocationManager).slashOperator(address(this), slashingParams);

        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: $.operatorSetIds[_operator] });

        // @dev clear the burn or redistributable shares, this sends them to the service manager
        IStrategyManager($.eigen.strategyManager).clearBurnOrRedistributableSharesByStrategy(
            operatorSet, slashId, _strategy
        );
    }

    /// @notice Create a rewards submission
    /// @param _operatorSet The operator set
    /// @param _rewardsSubmissions The rewards submissions being created
    function _createRewardsSubmission(
        IRewardsCoordinator.OperatorSet memory _operatorSet,
        IRewardsCoordinator.OperatorDirectedRewardsSubmission[] memory _rewardsSubmissions
    ) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IRewardsCoordinator($.eigen.rewardsCoordinator).createOperatorDirectedOperatorSetRewardsSubmission(
            _operatorSet, _rewardsSubmissions
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
    function _coverageByStrategy(address _operator, address _strategy, address _oracle)
        private
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address collateralAddress = address(IStrategy(_strategy).underlyingToken());
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        (uint256 collateralPrice,) = IOracle(_oracle).getPrice(collateralAddress);

        // @dev get the minimum slashable stake
        collateral = _minimumSlashableStake($.operatorToEigenOperator[_operator], _strategy);
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    /// @notice Get the slashable shares for a given operator and strategy
    /// @param _operator The operator address
    /// @return The slashable shares of the operator
    function _getSlashableShares(address _operator) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();

        address _strategy = $.operatorToStrategy[_operator];
        // Get the slashable shares for the operator/OperatorSet
        uint256 slashableShares = _minimumSlashableStake($.operatorToEigenOperator[_operator], _strategy);
        // Get the shares in queue
        uint256 sharesInQueue = _slashableSharesInQueue($.operatorToEigenOperator[_operator], _strategy);
        // Sum up the slashable shares and the shares in queue
        uint256 totalSlashableShares = slashableShares + sharesInQueue;

        return totalSlashableShares;
    }

    /// @notice Get the slashable shares in queue for withdrawal from a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The slashable shares in queue for withdrawal
    function _slashableSharesInQueue(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        // @dev get the slashable shares in queue which are waiting to be withdrawn
        return IDelegationManager($.eigen.delegationManager).getSlashableSharesInQueue(_operator, _strategy);
    }

    /// @notice Get the minimum slashable stake for a given operator and strategy
    /// @param _operator The operator address
    /// @param _strategy The strategy address
    /// @return The minimum slashable stake
    function _minimumSlashableStake(address _operator, address _strategy) private view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: $.operatorSetIds[_operator] });
        address[] memory operators = new address[](1);
        operators[0] = _operator;
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        // @dev get the minimum slashable stake at the current block
        uint256[][] memory slashableShares = IAllocationManager($.eigen.allocationManager).getMinimumSlashableStake(
            operatorSet, operators, strategies, uint32(block.number)
        );
        return slashableShares[0][0];
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
