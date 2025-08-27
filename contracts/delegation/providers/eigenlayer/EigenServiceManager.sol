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
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAVSDirectory } from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";

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

    /// @dev Operator registered
    event OperatorRegistered(address indexed operator, address indexed avs, uint32[] operatorSetIds);
    /// @dev Emitted on slash
    event Slash(address indexed agent, address indexed recipient, uint256 slashShare, uint48 timestamp);
    /// @dev Strategy registered
    event StrategyRegistered(address indexed strategy, address indexed operator);
    /// @dev Rewards duration set
    event RewardsDurationSet(uint32 rewardDuration);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenServiceManager
    function initialize(
        address _accessControl,
        address _allocationManager,
        address _delegationManager,
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
        $.oracle = _oracle;
        $.delegationManager = _delegationManager;
        $.rewardsCoordinator = _rewardsCoordinator;
        $.registryCoordinator = _registryCoordinator;
        $.stakeRegistry = _stakeRegistry;
        $.rewardDuration = _rewardDuration;
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
    function slashableCollateral(address operator, uint256) external view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[operator] == address(0)) revert ZeroAddress();
        return slashableCollateralByStrategy(operator, $.operatorToStrategy[operator]);
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

    /// @inheritdoc IEigenServiceManager
    function coverage(address operator) external view returns (uint256 delegation) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address _strategy = $.operatorToStrategy[operator];
        if (_strategy == address(0)) revert ZeroAddress();
        address _oracle = $.oracle;
        (delegation,) = coverageByStrategy(operator, _strategy, _oracle);
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

    /// @inheritdoc IEigenServiceManager
    function slash(address _operator, address _recipient, uint256 _slashShare, uint48)
        external
        checkAccess(this.slash.selector)
    {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        if ($.operatorToStrategy[_operator] == address(0)) revert ZeroAddress();

        address _strategy = $.operatorToStrategy[_operator];
        IERC20 _slashedCollateral = IStrategy(_strategy).underlyingToken();
        uint256 slashableShares = _getSlashableShares(_operator);

        // Round up in favor of the liquidator
        uint256 slashShareOfCollateral = (slashableShares * _slashShare / 1e18) + 1;

        // If the slash share is greater than the total slashable collateral, set it to the total slashable collateral
        if (slashShareOfCollateral > slashableShares) {
            slashShareOfCollateral = slashableShares;
        }

        _slash(_strategy, _operator, slashShareOfCollateral);
        _slashedCollateral.safeTransfer(_recipient, slashShareOfCollateral);

        emit Slash(_operator, _recipient, slashShareOfCollateral, uint48(block.timestamp));
    }

    /// @notice Slash the operator
    /// @param _strategy The strategy address
    /// @param _operator The operator address
    /// @param _slashShareOfCollateral The slash share of collateral
    function _slash(address _strategy, address _operator, uint256 _slashShareOfCollateral) private {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        uint256[] memory wadsToSlash = new uint256[](1);
        wadsToSlash[0] = _slashShareOfCollateral;

        IAllocationManager.SlashingParams memory slashingParams = IAllocationManager.SlashingParams({
            operator: _operator,
            operatorSetId: $.operatorSetIds[_operator],
            strategies: strategies,
            wadsToSlash: wadsToSlash,
            description: "liquidation"
        });

        IAllocationManager($.allocationManager).slashOperator(address(this), slashingParams);
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
        if ($.operatorToStrategy[_operator] != address(0)) revert AlreadyRegisteredOperator();
        if ($.operatorSetIds[_operator] == 0) revert InvalidOperator();
        $.operatorToStrategy[_operator] = _strategy;

        emit StrategyRegistered(_strategy, _operator);
    }

    function setRewardsDuration(uint32 _rewardDuration) external checkAccess(this.setRewardsDuration.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        $.rewardDuration = _rewardDuration;

        emit RewardsDurationSet(_rewardDuration);
    }

    /// @notice Create a rewards submission for the AVS
    /// @param rewardsSubmissions The rewards submissions being created
    function _createAVSRewardsSubmission(IRewardsCoordinator.RewardsSubmission[] memory rewardsSubmissions) internal {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        IRewardsCoordinator($.rewardsCoordinator).createAVSRewardsSubmission(rewardsSubmissions);
    }

    /// @notice Check if the token has enough allowance for the spender
    /// @param token The token to check
    /// @param spender The spender to check
    function _checkApproval(address token, address spender) internal {
        if (IERC20(token).allowance(spender, address(this)) == 0) {
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
