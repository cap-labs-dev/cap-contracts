// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEigenOperator } from "../../../interfaces/IEigenOperator.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { EigenOperatorStorageUtils } from "../../../storage/EigenOperatorStorageUtils.sol";

import { IAllocationManager } from "./interfaces/IAllocationManager.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { console } from "forge-std/console.sol";

/// @title EigenOperator
/// @author weso, Cap Labs
/// @notice This contract manages the eigen operator as proxy to disable some functionality
contract EigenOperator is IEigenOperator, Initializable, EigenOperatorStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenOperator
    function initialize(address _serviceManager, address _operator, string calldata _metadata) external initializer {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        $.serviceManager = _serviceManager;
        $.operator = _operator;

        // Fetch the eigen addresses
        IEigenServiceManager.EigenAddresses memory eigenAddresses =
            IEigenServiceManager(_serviceManager).eigenAddresses();
        $.allocationManager = eigenAddresses.allocationManager;
        $.delegationManager = eigenAddresses.delegationManager;
        $.rewardsCoordinator = eigenAddresses.rewardsCoordinator;

        // Register as an operator on delegation manager
        IDelegationManager($.delegationManager).registerAsOperator(address(0), 0, _metadata);
    }

    /// @inheritdoc IEigenOperator
    function registerOperatorSetToServiceManager(uint32 _operatorSetId) external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        if (msg.sender != $.serviceManager) revert NotServiceManager();

        // Build the register params
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = _operatorSetId;

        IAllocationManager.RegisterParams memory params =
            IAllocationManager.RegisterParams({ avs: msg.sender, operatorSetIds: operatorSetIds, data: "" });

        // 1. Register the operator set to the service manager, which in turn calls RegisterOperator on the Eigen Service Manager
        IAllocationManager($.allocationManager).registerForOperatorSets(address(this), params);

        // 2. Set the operator split to 0, all rewards go to restakers
        IRewardsCoordinator($.rewardsCoordinator).setOperatorAVSSplit(address(this), msg.sender, 0);
    }

    /// @inheritdoc IEigenOperator
    function allocate(uint32 _operatorSetId, address _strategy) external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        if (msg.sender != $.serviceManager) revert NotServiceManager();

        (, IAllocationManager.Allocation[] memory _allocations) =
            IAllocationManager($.allocationManager).getStrategyAllocations(address(this), _strategy);
        if (_allocations.length != 0) revert AlreadyAllocated();

        // The strategy that the restakers capital is deployed to
        address[] memory strategies = new address[](1);
        strategies[0] = _strategy;

        // Only 1 allocation so 1e18 just means everything will be allocated to the avs
        uint64[] memory magnitudes = new uint64[](1);
        magnitudes[0] = 1e18;

        // Create the allocation params
        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: msg.sender, id: _operatorSetId });
        IAllocationManager.AllocateParams[] memory allocations = new IAllocationManager.AllocateParams[](1);
        allocations[0] = IAllocationManager.AllocateParams({
            operatorSet: operatorSet,
            strategies: strategies,
            newMagnitudes: magnitudes
        });

        // Set the allocation for the operator set to the strategy
        IAllocationManager($.allocationManager).modifyAllocations(address(this), allocations);
    }

    /// @notice Update the operator metadata URI
    /// @param _metadataURI The new metadata URI
    function updateOperatorMetadataURI(string calldata _metadataURI) external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        if (msg.sender != $.operator) revert NotOperator();
        IDelegationManager($.delegationManager).updateOperatorMetadataURI(address(this), _metadataURI);
    }

    /// @inheritdoc IEigenOperator
    function eigenServiceManager() external view returns (address) {
        return getEigenOperatorStorage().serviceManager;
    }

    /// @inheritdoc IEigenOperator
    function operator() external view returns (address) {
        return getEigenOperatorStorage().operator;
    }
}
