// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenAddressbook, EigenUtils } from "../../../../../contracts/deploy/utils/EigenUtils.sol";

import { MockERC20 } from "../../../../mocks/MockERC20.sol";
import { TestEnvConfig, UsersConfig } from "../../../interfaces/TestDeployConfig.sol";

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { EigenServiceManager } from "../../../../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IAllocationManager } from
    "../../../../../contracts/delegation/providers/eigenlayer/interfaces/IAllocationManager.sol";
import { IDelegationManager } from
    "../../../../../contracts/delegation/providers/eigenlayer/interfaces/IDelegationManager.sol";
import { IStrategy } from "../../../../../contracts/delegation/providers/eigenlayer/interfaces/IStrategy.sol";
import { IStrategyManager } from
    "../../../../../contracts/delegation/providers/eigenlayer/interfaces/IStrategyManager.sol";
import { InfraConfig } from "../../../interfaces/TestDeployConfig.sol";
import { TimeUtils } from "../../../utils/TimeUtils.sol";

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract InitEigenDelegations is Test, EigenUtils, TimeUtils {
    function _initEigenDelegations(
        EigenAddressbook memory eigenAb,
        address agent,
        address restaker,
        uint256 amountNoDecimals
    ) internal {
        _initEigenDelegationsForAgent(eigenAb, agent, restaker, amountNoDecimals);
        _timeTravel(28 days);
    }

    function _initEigenDelegationsForAgent(
        EigenAddressbook memory eigenAb,
        address agent,
        address restaker,
        uint256 amountNoDecimals
    ) internal returns (uint256 depositedAmount, uint256 mintedShares) {
        address strategy = eigenAb.eigenAddresses.strategy;
        address collateral = address(IStrategy(strategy).underlyingToken());
        uint256 amount = amountNoDecimals * 10 ** MockERC20(collateral).decimals();

        (uint256 restakerDepositedAmount, uint256 restakerMintedShares) =
            _eigenMintAndStakeInStrategy(eigenAb, strategy, agent, restaker, amount);
        depositedAmount = restakerDepositedAmount;
        mintedShares = restakerMintedShares;
    }

    function _eigenMintAndStakeInStrategy(
        EigenAddressbook memory eigenAb,
        address strategy,
        address agent,
        address restaker,
        uint256 amount
    ) internal returns (uint256 depositedAmount, uint256 mintedShares) {
        vm.startPrank(restaker);
        address collateral = address(IStrategy(strategy).underlyingToken());
        deal(collateral, restaker, amount);
        MockERC20(collateral).approve(eigenAb.eigenAddresses.strategyManager, amount);
        IStrategyManager(eigenAb.eigenAddresses.strategyManager).depositIntoStrategy(strategy, collateral, amount);
        depositedAmount = amount;
        (, uint256[] memory shares) =
            IDelegationManager(eigenAb.eigenAddresses.delegationManager).getDepositedShares(restaker);
        mintedShares = shares[0];

        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry =
            IDelegationManager.SignatureWithExpiry({ signature: "", expiry: 0 });
        IDelegationManager(eigenAb.eigenAddresses.delegationManager).delegateTo(agent, signatureWithExpiry, bytes32(0));
        vm.stopPrank();
    }

    function _proportionallyWithdrawFromStrategy(
        EigenAddressbook memory eigenAb,
        address restaker,
        address strategy,
        uint256 amount,
        bool all
    ) internal returns (bytes32 withdrawalRoot) {
        if (all) {
            (address[] memory strategies, uint256[] memory shares) =
                IDelegationManager(eigenAb.eigenAddresses.delegationManager).getDepositedShares(restaker);
            vm.startPrank(restaker);
            IDelegationManager.QueuedWithdrawalParams[] memory params =
                new IDelegationManager.QueuedWithdrawalParams[](1);
            params[0].strategies = strategies;
            params[0].depositShares = shares;
            params[0].__deprecated_withdrawer = restaker;
            bytes32[] memory withdrawalRoots =
                IDelegationManager(eigenAb.eigenAddresses.delegationManager).queueWithdrawals(params);
            withdrawalRoot = withdrawalRoots[0];
            vm.stopPrank();
        } else {
            vm.startPrank(restaker);
            IDelegationManager.QueuedWithdrawalParams[] memory params =
                new IDelegationManager.QueuedWithdrawalParams[](1);
            params[0].strategies = new address[](1);
            params[0].strategies[0] = strategy;
            params[0].depositShares = new uint256[](1);
            params[0].depositShares[0] = amount;
            params[0].__deprecated_withdrawer = restaker;
            bytes32[] memory withdrawalRoots =
                IDelegationManager(eigenAb.eigenAddresses.delegationManager).queueWithdrawals(params);
            withdrawalRoot = withdrawalRoots[0];
            vm.stopPrank();
        }
    }

    function _completeWithdrawal(
        EigenAddressbook memory eigenAb,
        address restaker,
        address operator,
        uint256 nonce,
        uint32 startBlock,
        address strategy,
        uint256 shares
    ) internal {
        vm.startPrank(restaker);
        address[] memory strategies = new address[](1);
        strategies[0] = strategy;
        uint256[] memory scaledShares = new uint256[](1);
        scaledShares[0] = shares;
        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: restaker,
            delegatedTo: operator,
            withdrawer: restaker,
            nonce: nonce,
            startBlock: startBlock,
            strategies: strategies,
            scaledShares: scaledShares
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(IStrategy(strategy).underlyingToken());
        IDelegationManager(eigenAb.eigenAddresses.delegationManager).completeQueuedWithdrawal(withdrawal, tokens, true);
        vm.stopPrank();
    }

    function _agentRegisterAsOperator(EigenAddressbook memory eigenAb, address agent) internal {
        vm.startPrank(agent);
        IDelegationManager(eigenAb.eigenAddresses.delegationManager).registerAsOperator(address(0), 0, "");
        vm.stopPrank();
    }

    function _registerToEigenServiceManager(
        EigenAddressbook memory eigenAb,
        address admin,
        address eigenServiceManager,
        address agent
    ) internal {
        vm.startPrank(admin);
        uint256 operatorId =
            EigenServiceManager(eigenServiceManager).registerStrategy(eigenAb.eigenAddresses.strategy, agent, "");
        vm.stopPrank();

        vm.startPrank(agent);
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = uint32(operatorId);
        IAllocationManager.RegisterParams memory params =
            IAllocationManager.RegisterParams({ avs: eigenServiceManager, operatorSetIds: operatorSetIds, data: "" });
        IAllocationManager(eigenAb.eigenAddresses.allocationManager).registerForOperatorSets(agent, params);

        address[] memory strategies = new address[](1);
        strategies[0] = eigenAb.eigenAddresses.strategy;

        uint64[] memory magnitudes = new uint64[](1);
        magnitudes[0] = 1e18;

        IAllocationManager.OperatorSet memory operatorSet =
            IAllocationManager.OperatorSet({ avs: eigenServiceManager, id: uint32(operatorSetIds[0]) });

        IAllocationManager.AllocateParams[] memory allocations = new IAllocationManager.AllocateParams[](1);
        allocations[0] = IAllocationManager.AllocateParams({
            operatorSet: operatorSet,
            strategies: strategies,
            newMagnitudes: magnitudes
        });

        IAllocationManager(eigenAb.eigenAddresses.allocationManager).modifyAllocations(agent, allocations);
        vm.stopPrank();
    }
}
