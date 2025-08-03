// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { EigenServiceManagerStorageUtils } from "../../../storage/EigenServiceManagerStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAVSDirectory } from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import { IDelegationManager, IStrategy } from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import { IRegistryCoordinator } from "eigenlayer/src/interfaces/IRegistryCoordinator.sol";
import { IStakeRegistry } from "eigenlayer/src/interfaces/IStakeRegistry.sol";

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

    ///// TO DO
    /// @inheritdoc IEigenServiceManager
    /*function createAVSRewardsSubmission(
        IRewardsCoordinator.RewardsSubmission[] calldata rewardsSubmissions
    ) external checkAccess(this.createAVSRewardsSubmission.selector) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        for (uint256 i = 0; i < rewardsSubmissions.length; ++i) {
            // transfer token to ServiceManager and approve RewardsCoordinator to transfer again
            // in createAVSRewardsSubmission() call
            rewardsSubmissions[i].token.safeTransferFrom(
                msg.sender, address(this), rewardsSubmissions[i].amount
            );
            rewardsSubmissions[i].token.safeIncreaseAllowance(
                address($.rewardsCoordinator), rewardsSubmissions[i].amount
            );
        }

        $.rewardsCoordinator.createAVSRewardsSubmission(rewardsSubmissions);
    }*/

    /// @inheritdoc IEigenServiceManager
    function avsDirectory() external view override returns (address) {
        EigenServiceManagerStorage storage $ = getEigenServiceManagerStorage();
        return $.avsDirectory;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
