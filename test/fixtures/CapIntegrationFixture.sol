// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IAllocationManager } from "../../contracts/delegation/providers/eigenlayer/interfaces/IAllocationManager.sol";
import { IStrategyManager } from "../../contracts/delegation/providers/eigenlayer/interfaces/IStrategyManager.sol";
import { IEigenServiceManager } from "../../contracts/interfaces/IEigenServiceManager.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { Vm } from "forge-std/Vm.sol";

/// @dev Common setup wrapper around `TestDeployer` so integration tests read consistently.
///
/// The default `TestDeployer` behavior is fork-first (unless the harness config selects mock mode).
/// These helpers intentionally keep that behavior and only reduce boilerplate in individual suites.
abstract contract CapIntegrationFixture is TestDeployer {
    function _setUpCap() internal {
        _deployCapTestEnvironment();
    }

    function _setUpCapWithUsdVaultLiquidity() internal {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
    }

    function _setUpCapWithUsdVaultAndSymbioticLiquidity(uint256 symbioticAmountNoDecimals) internal {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env, symbioticAmountNoDecimals);
    }

    /// @dev Completes every eigen slash queued in `logs` (from `vm.getRecordedLogs()`), paying the recipients
    function _completeQueuedEigenSlashes(Vm.Log[] memory logs) internal {
        address eigenServiceManager = env.eigen.eigenConfig.eigenServiceManager;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != eigenServiceManager) continue;
            if (logs[i].topics[0] != IEigenServiceManager.SlashQueued.selector) continue;
            address agent = address(uint160(uint256(logs[i].topics[1])));
            (uint256 slashId,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            _rollPastEigenSlashResolution(agent, slashId);
            IEigenServiceManager(eigenServiceManager).completeSlash(agent, slashId);
        }
    }

    /// @dev Rolls past eigen's slash resolution delay (ELIP-016) so the slash can be completed
    function _rollPastEigenSlashResolution(address agent, uint256 slashId) internal {
        IEigenServiceManager eigenServiceManager = IEigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
        uint32 resolutionBlock = IStrategyManager(eigenServiceManager.eigenAddresses().strategyManager)
            .getSlashResolutionBlock(_eigenOperatorSet(agent), slashId);
        if (block.number <= resolutionBlock) vm.roll(uint256(resolutionBlock) + 1);
    }

    /// @dev The eigen operator set of an agent
    function _eigenOperatorSet(address agent) internal view returns (IAllocationManager.OperatorSet memory) {
        IEigenServiceManager eigenServiceManager = IEigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
        return IAllocationManager.OperatorSet({
            avs: address(eigenServiceManager), id: eigenServiceManager.operatorSetId(agent)
        });
    }
}

