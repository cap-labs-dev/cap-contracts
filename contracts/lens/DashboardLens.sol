// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILender } from "../interfaces/ILender.sol";
import { ISymbioticNetworkMiddleware } from "../interfaces/ISymbioticNetworkMiddleware.sol";
import {
    IOperatorNetworkSpecificDelegator
} from "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { IDelegationManager } from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import { IStrategy } from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import { IStrategyManager } from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";

// ─── Residual Local Interface ─────────────────────────────────────────────────
// IAllocationManager.getAllocationDelay was introduced in EigenLayer ELIP-002,
// which postdates eigenlayer-contracts@1.0.4 (the version in this project).
// It is not present in any available library interface, so it stays local.

interface IAllocationManagerLens {
    function getAllocationDelay(address operator) external view returns (bool isSet, uint32 delay);
}

// ─── Structs ─────────────────────────────────────────────────────────────────

struct SymbioticVaultSnapshot {
    uint256 activeStake;
    uint256 depositorActiveBalance;
    uint256 depositorWithdrawalAmount;
    uint256 withdrawalEpoch;
    uint256 currentEpoch;
    uint256 epochDuration;
    uint256 nextEpochStart;
    bool isWhitelistEnabled;
    address collateralToken;
    uint256 depositorActiveShares;
    bool depositorIsWhitelisted;
    uint256 activeShares;
    bool isDepositLimit;
    uint256 depositLimit;
    address burner;
    address delegator;
    bool isDelegatorInitialized;
    address slasher;
    bool isSlasherInitialized;
    bool isCapNetworkVault;
}

struct EigenLayerSnapshot {
    uint256 depositedShares;
    uint256 depositedAmount;
    address delegatee;
    bool isDelegated;
    uint32 allocationDelay;
    bool allocationDelayPending;
}

struct LoanSnapshot {
    uint256 totalDelegation;
    uint256 totalSlashableCollateral;
    uint256 totalDebt;
    uint256 ltv;
    uint256 liquidationThreshold;
    uint256 health;
    uint256 accruedRestakerInterest;
    uint256 maxBorrowable;
}

// ─── DashboardLens ───────────────────────────────────────────────────────────

/// @title DashboardLens
/// @notice Read-only aggregation contract for the CAP Underwriter Dashboard.
///         Batches multiple external contract reads into a single call to reduce
///         RPC round-trips and avoid rate limiting.
/// @dev No state, no write functions, no access control — purely a view utility.
contract DashboardLens {
    ILender public constant LENDER = ILender(0x15622c3dbbc5614E6DFa9446603c1779647f01FC);
    IOptInService public constant VAULT_OPT_IN_SERVICE = IOptInService(0xb361894bC06cbBA7Ea8098BF0e32EB1906A5F891);

    // ─── Symbiotic ───────────────────────────────────────────────────────────

    /// @notice Returns a snapshot of a single Symbiotic vault for a given depositor.
    /// @param vault      The Symbiotic vault contract address.
    /// @param depositor  The address whose balance and withdrawal state to read.
    ///                   For a CAP delegator, pass the delegator's agent address.
    function getSymbioticVaultSnapshot(address vault, address depositor)
        external
        view
        returns (SymbioticVaultSnapshot memory snapshot)
    {
        IVault v = IVault(vault);

        snapshot.depositorActiveBalance = v.activeBalanceOf(depositor);
        snapshot.depositorActiveShares = v.activeSharesOf(depositor);
        snapshot.depositorIsWhitelisted = v.isDepositorWhitelisted(depositor);

        snapshot.activeStake = v.activeStake();
        snapshot.currentEpoch = v.currentEpoch();
        snapshot.withdrawalEpoch = snapshot.currentEpoch + 1;
        snapshot.depositorWithdrawalAmount = v.withdrawalsOf(snapshot.withdrawalEpoch, depositor);
        uint48 duration = v.epochDuration();
        snapshot.epochDuration = uint256(duration);
        snapshot.nextEpochStart = uint256(v.nextEpochStart());
        snapshot.isWhitelistEnabled = v.depositWhitelist();
        snapshot.collateralToken = v.collateral();

        snapshot.activeShares = v.activeShares();
        snapshot.isDepositLimit = v.isDepositLimit();
        snapshot.depositLimit = v.depositLimit();
        snapshot.burner = v.burner();
        snapshot.delegator = v.delegator();
        snapshot.isDelegatorInitialized = v.isDelegatorInitialized();
        snapshot.slasher = v.slasher();
        snapshot.isSlasherInitialized = v.isSlasherInitialized();

        try IOperatorNetworkSpecificDelegator(snapshot.delegator).operator() returns (address operator) {
            try VAULT_OPT_IN_SERVICE.isOptedIn(operator, vault) returns (bool opted) {
                snapshot.isCapNetworkVault = opted;
            } catch { }
        } catch { }
    }

    /// @notice Returns snapshots for multiple Symbiotic vaults in a single call.
    ///         Failed vault reads (e.g. paused or incompatible vault) return a zero-value struct
    ///         rather than reverting the entire batch.
    /// @param vaults     Array of Symbiotic vault addresses.
    /// @param depositor  The address to read balances for.
    function getSymbioticVaultBatch(address[] calldata vaults, address depositor)
        external
        view
        returns (SymbioticVaultSnapshot[] memory snapshots)
    {
        snapshots = new SymbioticVaultSnapshot[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            try this.getSymbioticVaultSnapshot(vaults[i], depositor) returns (SymbioticVaultSnapshot memory s) {
                snapshots[i] = s;
            } catch {
                // Leave snapshots[i] as zero-value struct
            }
        }
    }

    // ─── EigenLayer ──────────────────────────────────────────────────────────

    /// @notice Returns a snapshot of a single EigenLayer strategy for a given staker.
    /// @param strategy           The EigenLayer strategy contract address.
    /// @param staker             The depositor / staker address.
    /// @param strategyManager    IStrategyManager for getDeposits().
    /// @param delegationManager  IDelegationManager for delegatedTo() / isDelegated().
    /// @param allocationManager  IAllocationManager for getAllocationDelay().
    function getEigenLayerSnapshot(
        address strategy,
        address staker,
        address strategyManager,
        address delegationManager,
        address allocationManager
    ) external view returns (EigenLayerSnapshot memory snapshot) {
        IDelegationManager dm = IDelegationManager(delegationManager);

        snapshot.isDelegated = dm.isDelegated(staker);
        snapshot.delegatee = dm.delegatedTo(staker);

        // Get deposited shares for the requested strategy.
        // IStrategyManager.getDeposits returns IStrategy[] (not address[]), so cast for comparison.
        (IStrategy[] memory strategies, uint256[] memory shares) = IStrategyManager(strategyManager).getDeposits(staker);

        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == strategy) {
                snapshot.depositedShares = shares[i];
                break;
            }
        }

        if (snapshot.depositedShares > 0) {
            snapshot.depositedAmount = IStrategy(strategy).sharesToUnderlyingView(snapshot.depositedShares);
        }

        // Allocation delay only meaningful when staker is delegated to an operator
        if (snapshot.delegatee != address(0)) {
            (bool isSet, uint32 delay) =
                IAllocationManagerLens(allocationManager).getAllocationDelay(snapshot.delegatee);
            snapshot.allocationDelayPending = !isSet;
            snapshot.allocationDelay = delay;
        }
    }

    // ─── CAP Lender ──────────────────────────────────────────────────────────

    /// @notice Returns a comprehensive snapshot of a CAP loan position.
    ///         Combines Lender.agent() (6 values) with accruedRestakerInterest and maxBorrowable.
    /// @param agent  The delegator agent address.
    /// @param asset  The borrowed asset address.
    function getLoanSnapshot(address agent, address asset) external view returns (LoanSnapshot memory snapshot) {
        try LENDER.agent(agent) returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        ) {
            snapshot.totalDelegation = totalDelegation;
            snapshot.totalSlashableCollateral = totalSlashableCollateral;
            snapshot.totalDebt = totalDebt;
            snapshot.ltv = ltv;
            snapshot.liquidationThreshold = liquidationThreshold;
            snapshot.health = health;
        } catch {
            snapshot.totalDelegation = 0;
            snapshot.totalSlashableCollateral = 0;
            snapshot.totalDebt = 0;
            snapshot.ltv = 0;
            snapshot.liquidationThreshold = 0;
            snapshot.health = 0;
        }
        // Try to call accruedRestakerInterest, set to 0 if it fails
        try LENDER.accruedRestakerInterest(agent, asset) returns (uint256 interest) {
            snapshot.accruedRestakerInterest = interest;
        } catch {
            snapshot.accruedRestakerInterest = 0;
        }
        // Try to call maxBorrowable, set to 0 if it fails
        try LENDER.maxBorrowable(agent, asset) returns (uint256 maxBorrow) {
            snapshot.maxBorrowable = maxBorrow;
        } catch {
            snapshot.maxBorrowable = 0;
        }
    }
}
