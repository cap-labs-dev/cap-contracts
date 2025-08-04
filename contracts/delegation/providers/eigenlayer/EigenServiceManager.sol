// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";

import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAVSDirectory } from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import { IDelegationManager } from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import { IStakeRegistry } from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

contract EigenServiceManager is IEigenServiceManager, UUPSUpgradeable, Access, EigenServiceManagerStorageUtils {
    using SafeERC20 for IERC20;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenServiceManager
    function initialize(
        address _accessControl,
        address _avsDirectory,
        address _rewardsCoordinator,
        address _registryCoordinator,
        address _stakeRegistry
    ) external initializer {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.avsDirectory = _avsDirectory;
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
        IAVSDirectory($.avsDirectory).updateAVSMetadataURI(_metadataURI);
    }

    /*
    /// @notice Calculate the slashable shares for an operator at the current block
    /// @param operator The operator to calculate the slashable shares for
    /// @return The slashable shares of the operator
    function calculateSlashableShares(
        address operator
    ) public view returns (uint256) {
        // Get the slashable shares for the operator/OperatorSet
        address[] memory operators = new address[](1);
        operators[0] = operator;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = strategy;
        uint256[][] memory slashableShares = allocationManager.getMinimumSlashableStake(operatorSet, operators, strategies, uint32(block.number));

        // Get the shares in queue
        uint256 sharesInQueue = delegationManager.getSlashableSharesInQueue(operator, strategy);

        // Sum up the slashable shares and the shares in queue
        uint256 totalSlashableShares = slashableShares[0][0] + sharesInQueue;

        return totalSlashableShares;
    }*/

    /// @inheritdoc IEigenServiceManager
    function distributeRewards(address _agent, address _token) external checkAccess(this.distributeRewards.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
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
        for (uint256 i; i < rewardsSubmissions.length; ++i) {
            _checkApproval(rewardsSubmissions[i].token, $.rewardsCoordinator);
        }

        IRewardsCoordinator($.rewardsCoordinator).createAVSRewardsSubmission(rewardsSubmissions);
    }

    /// @inheritdoc IEigenServiceManager
    function avsDirectory() external view override returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.avsDirectory;
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
