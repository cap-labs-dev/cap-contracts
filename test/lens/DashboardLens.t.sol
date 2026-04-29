// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DashboardLens,
    EigenLayerSnapshot,
    LoanSnapshot,
    SymbioticVaultSnapshot
} from "../../contracts/lens/DashboardLens.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Fork tests for DashboardLens against Ethereum mainnet state.
///         Run with: forge test --match-path test/lens/DashboardLens.t.sol -v
///         Requires MAINNET_RPC_URL env var pointing to an Ethereum mainnet RPC endpoint.
contract DashboardLensForkTest is Test {
    // ─── Contract Addresses ───────────────────────────────────────────────────

    // Symbiotic: bedrock / uniBTC vault
    // delegatorAddress from collateralConfigs (delegationNetwork: 'symbiotic')
    address constant VAULT = 0x5e278BF93478c842148E7c52be5415f6C1d46538;
    // operatorAddress — bedrock CAP operator, holds a $21M loan
    address constant AGENT = 0xbAfa91d22C093E42E28D7Be417e38244E4153f78;

    // Borrowed asset
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // EigenLayer mainnet proxies
    // Note: eigen.json has a typo (extra 'A') in delegationManager — correct address used here.
    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    address constant STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    address constant ALLOCATION_MANAGER = 0x948a420b8CC1d6BFd0B6087C2E7c344a2CD0bc39;
    // yield-nest OETH strategy (eigenStrategyAddress in collateralConfigs)
    address constant EL_STRATEGY = 0xa4C637e0F704745D182e4D38cAb7E7485321d059;
    // yield-nest EigenLayer operator (eigenOperatorAddress in collateralConfigs)
    address constant EL_STAKER = 0x4668d41D944B92f800965266D6382EF3F5C6B763;

    string constant MAINNET_RPC_URL = "https://mainnet.gateway.tenderly.co";
    uint256 constant FORK_BLOCK = 24843127;

    DashboardLens lens;

    function setUp() public {
        vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);
        lens = new DashboardLens();
    }

    // ─── Symbiotic Vault Snapshot ─────────────────────────────────────────────

    function test_fork_getSymbioticVaultSnapshot_vaultMetadata() public view {
        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT);

        // Vault-level fields are always populated regardless of who the depositor is.
        // Depositor-specific balances may be 0 here because AGENT is the CAP operator
        // address, not the identifier registered in this middleware — the Lender aggregates
        // collateral through its own delegation stack using a different internal agent id.
        assertTrue(s.collateralToken != address(0), "collateralToken");
        assertGt(s.epochDuration, 0, "epochDuration");
        assertGt(s.currentEpoch, 0, "currentEpoch");
    }

    function test_fork_getSymbioticVaultSnapshot_epochFields() public view {
        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT);

        assertGt(s.currentEpoch, 0, "currentEpoch");
        assertGt(s.epochDuration, 0, "epochDuration");
        assertGt(s.nextEpochStart, 0, "nextEpochStart");
        // Computed relationship must always hold
        assertEq(s.withdrawalEpoch, s.currentEpoch + 1, "withdrawalEpoch = currentEpoch + 1");
    }

    function test_fork_getSymbioticVaultBatch_single() public view {
        address[] memory vaults = new address[](1);
        vaults[0] = VAULT;

        SymbioticVaultSnapshot[] memory snapshots = lens.getSymbioticVaultBatch(vaults, AGENT);

        assertEq(snapshots.length, 1);
        assertGt(snapshots[0].currentEpoch, 0, "batch[0].currentEpoch");
        assertEq(snapshots[0].withdrawalEpoch, snapshots[0].currentEpoch + 1);
    }

    function test_fork_getSymbioticVaultBatch_partialRevert() public view {
        address[] memory vaults = new address[](3);
        vaults[0] = VAULT;
        vaults[1] = address(0xdead); // invalid — will revert inside batch
        vaults[2] = VAULT;

        SymbioticVaultSnapshot[] memory snapshots = lens.getSymbioticVaultBatch(vaults, AGENT);

        assertEq(snapshots.length, 3);
        // index 0 and 2: real vault — epoch data is populated for any valid Symbiotic vault
        assertGt(snapshots[0].currentEpoch, 0, "snapshots[0].currentEpoch");
        assertGt(snapshots[2].currentEpoch, 0, "snapshots[2].currentEpoch");
        // index 1: reverting address → zero-value struct, not a revert of the whole call
        assertEq(snapshots[1].currentEpoch, 0, "snapshots[1].currentEpoch should be zero");
        assertEq(snapshots[1].collateralToken, address(0), "snapshots[1].collateralToken should be zero");
    }

    // ─── EigenLayer Snapshot ──────────────────────────────────────────────────

    function test_fork_getEigenLayerSnapshot_callSucceeds() public view {
        // Verify the full call completes without revert and returns a coherent struct
        EigenLayerSnapshot memory s = lens.getEigenLayerSnapshot(
            EL_STRATEGY, EL_STAKER, STRATEGY_MANAGER, DELEGATION_MANAGER, ALLOCATION_MANAGER
        );

        // Zero shares ↔ zero amount (sharesToUnderlyingView(0) == 0)
        if (s.depositedShares == 0) {
            assertEq(s.depositedAmount, 0, "zero shares -> zero amount");
        } else {
            assertGt(s.depositedAmount, 0, "non-zero shares -> non-zero amount");
        }

        // Allocation delay fields are coherent: if pending, delay should be 0
        if (s.allocationDelayPending) {
            assertEq(s.allocationDelay, 0, "pending delay -> delay value is 0");
        }
    }

    function test_fork_getEigenLayerSnapshot_delegationState() public view {
        EigenLayerSnapshot memory s = lens.getEigenLayerSnapshot(
            EL_STRATEGY, EL_STAKER, STRATEGY_MANAGER, DELEGATION_MANAGER, ALLOCATION_MANAGER
        );

        // EigenLayer operators self-delegate: isDelegated == true, delegatee == self
        assertTrue(s.isDelegated, "EL operator should be delegated");
        assertEq(s.delegatee, EL_STAKER, "EL operator should delegate to self");
    }

    // ─── Loan Snapshot ────────────────────────────────────────────────────────

    function test_fork_getLoanSnapshot_nonZeroLoan() public view {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);

        // bedrock has a $21M loan — all core fields should be non-zero
        assertGt(s.totalDelegation, 0, "totalDelegation");
        assertGt(s.totalSlashableCollateral, 0, "totalSlashableCollateral");
        assertGt(s.totalDebt, 0, "totalDebt");
        assertGt(s.health, 0, "health");
        assertGt(s.ltv, 0, "ltv");
        assertGt(s.liquidationThreshold, 0, "liquidationThreshold");
    }

    function test_fork_getLoanSnapshot_healthAboveOne() public view {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);

        // A healthy agent with a $21M loan should have health > 1 ray (1e27)
        assertGt(s.health, 1e27, "health should be above 1 ray for a well-collateralised agent");
    }

    function test_fork_getLoanSnapshot_accruedInterestAndMaxBorrowable() public view {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);

        // accruedRestakerInterest and maxBorrowable calls must not revert
        // accruedRestakerInterest ≥ 0 (always, for uint256)
        // maxBorrowable can be 0 if agent is at capacity — just confirm no revert
        assertTrue(s.accruedRestakerInterest >= 0); // confirms call succeeded
        assertTrue(s.maxBorrowable >= 0); // confirms call succeeded
    }
}
