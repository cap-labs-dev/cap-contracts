// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";

import { IAllocationManager } from "./interfaces/IAllocationManager.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAVSDirectory } from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import { IStakeRegistry } from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

contract EigenServiceManager is IEigenServiceManager, UUPSUpgradeable, Access, EigenServiceManagerStorageUtils {
    using SafeERC20 for IERC20;

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
        address _stakeRegistry
    ) external initializer {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.allocationManager = _allocationManager;
        $.delegationManager = _delegationManager;
        $.rewardsCoordinator = _rewardsCoordinator;
        $.registryCoordinator = _registryCoordinator;
        $.stakeRegistry = _stakeRegistry;
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
        return getSlashableShares(operator);
    }

    /// @notice Calculate the slashable shares for an operator at the current block
    /// @param operator The operator to calculate the slashable shares for
    /// @return The slashable shares of the operator
    function getSlashableShares(address operator) public view returns (uint256) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        address _strategy = $.agentToStrategy[operator];
        // Get the slashable shares for the operator/OperatorSet
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: address(this), id: 0 });
        address[] memory operators = new address[](1);
        operators[0] = operator;
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;
        uint256[][] memory slashableShares = IAllocationManager($.allocationManager).getMinimumSlashableStake(
            operatorSet, operators, strategies, uint32(block.number)
        );

        // Get the shares in queue
        uint256 sharesInQueue = IDelegationManager($.delegationManager).getSlashableSharesInQueue(operator, _strategy);

        // Sum up the slashable shares and the shares in queue
        uint256 totalSlashableShares = slashableShares[0][0] + sharesInQueue;

        return totalSlashableShares;
    }

    /// @inheritdoc IEigenServiceManager
    function distributeRewards(address _agent, address _token) external checkAccess(this.distributeRewards.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        _checkApproval(_token, $.rewardsCoordinator);
        uint256 _amount = IERC20(_token).balanceOf(address(this));
        address _strategy = $.agentToStrategy[_agent];

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
            duration: 0
        });

        _createAVSRewardsSubmission(rewardsSubmissions);
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
