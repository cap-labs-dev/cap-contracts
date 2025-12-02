// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEigenOperator } from "../../../interfaces/IEigenOperator.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { EigenOperatorStorageUtils } from "../../../storage/EigenOperatorStorageUtils.sol";
import { IAllocationManager } from "./interfaces/IAllocationManager.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "./interfaces/IRewardsCoordinator.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title EigenOperator
/// @author weso, Cap Labs
/// @notice This contract manages the eigen operator as proxy to disable some functionality for operators
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
        $.totpPeriod = 28 days; // Arbitrary value

        // Fetch the eigen addresses
        IEigenServiceManager.EigenAddresses memory eigenAddresses =
            IEigenServiceManager(_serviceManager).eigenAddresses();
        $.allocationManager = eigenAddresses.allocationManager;
        $.delegationManager = eigenAddresses.delegationManager;
        $.rewardsCoordinator = eigenAddresses.rewardsCoordinator;

        // Register as an operator on delegation manager
        IDelegationManager($.delegationManager).registerAsOperator(address(this), 0, _metadata);
    }

    /// @inheritdoc IEigenOperator
    function registerOperatorSetToServiceManager(uint32 _operatorSetId, address _staker) external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        if (msg.sender != $.serviceManager) revert NotServiceManager();
        if ($.restaker != address(0)) revert AlreadyRegistered();
        if (_staker == address(0)) revert ZeroAddress();

        /// @dev The digest is calculated using the staker and operator addresses
        bytes32 digest = calculateTotpDigestHash(_staker, address(this));
        /// @dev Allowlist the digest for delegation approval from the staker
        $.allowlistedDigests[digest] = true;
        $.restaker = _staker;

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

        // Allocates the operator set. Can only be called after ALLOCATION_CONFIGURATION_DELAY (approximately 17.5 days) has passed since registration.
        IAllocationManager($.allocationManager).modifyAllocations(address(this), allocations);
    }

    /// @inheritdoc IEigenOperator
    function updateOperatorMetadataURI(string calldata _metadataURI) external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        if (msg.sender != $.operator) revert NotOperator();
        IDelegationManager($.delegationManager).updateOperatorMetadataURI(address(this), _metadataURI);
    }

    /// @inheritdoc IEigenOperator
    function advanceTotp() external {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();

        // If for some reason the delegation approval has expired, allowlist the new digest
        bytes32 digest = calculateTotpDigestHash($.restaker, address(this));
        $.allowlistedDigests[digest] = true;
    }

    /// @inheritdoc IEigenOperator
    function eigenServiceManager() external view returns (address) {
        return getEigenOperatorStorage().serviceManager;
    }

    /// @inheritdoc IEigenOperator
    function operator() external view returns (address) {
        return getEigenOperatorStorage().operator;
    }

    /// @inheritdoc IEigenOperator
    function restaker() external view returns (address) {
        return getEigenOperatorStorage().restaker;
    }

    /// @inheritdoc IEigenOperator
    function isValidSignature(bytes32 _digest, bytes memory) external view override returns (bytes4 magicValue) {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();

        /// If the created at epoch is > the current epoch, the operator is not allowed to delegate
        uint32 createdAtEpoch = IEigenServiceManager($.serviceManager).createdAtEpoch($.operator);
        uint256 calcIntervalSeconds = IEigenServiceManager($.serviceManager).calculationIntervalSeconds();
        uint32 currentEpoch = uint32(block.timestamp / calcIntervalSeconds);

        if (createdAtEpoch > currentEpoch) return bytes4(0xffffffff);

        // This gets called by the delegation manager to check if the operator is allowed to delegate
        if ($.allowlistedDigests[_digest]) {
            return bytes4(0x1626ba7e); // ERC1271 magic value for valid signatures
        } else {
            return bytes4(0xffffffff);
        }
    }

    /// @inheritdoc IEigenOperator
    function getCurrentTotpExpiryTimestamp() public view returns (uint256) {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        uint256 current = block.timestamp / $.totpPeriod;
        return (current + 1) * $.totpPeriod; // End of the current period
    }

    /// @inheritdoc IEigenOperator
    function currentTotp() public view returns (uint256) {
        EigenOperatorStorage storage $ = getEigenOperatorStorage();
        return block.timestamp / $.totpPeriod;
    }

    /// @inheritdoc IEigenOperator
    function calculateTotpDigestHash(address _staker, address _operator) public view returns (bytes32) {
        uint256 expiryTimestamp = getCurrentTotpExpiryTimestamp();
        return IDelegationManager(getEigenOperatorStorage().delegationManager).calculateDelegationApprovalDigestHash(
            _staker, _operator, address(this), bytes32(uint256(expiryTimestamp)), expiryTimestamp
        );
    }
}
