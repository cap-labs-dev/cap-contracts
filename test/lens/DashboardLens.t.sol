// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDelegation } from "../../contracts/interfaces/IDelegation.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import {
    AgentCoverageSnapshot,
    AgentSnapshot,
    DashboardLens,
    EigenLayerSnapshot,
    LoanSnapshot,
    ReserveSnapshot,
    StakerRewardsTokenSnapshot,
    SymbioticVaultSnapshot
} from "../../contracts/lens/DashboardLens.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IOperatorNetworkSpecificDelegator
} from "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import {
    IDefaultStakerRewards
} from "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Fork tests for DashboardLens against Ethereum mainnet state.
///         Run with: forge test --match-path test/lens/DashboardLens.t.sol -v
contract DashboardLensForkTest is Test {
    address constant VAULT = 0x5e278BF93478c842148E7c52be5415f6C1d46538;
    address constant AGENT = 0xbAfa91d22C093E42E28D7Be417e38244E4153f78;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // cap-symbiotic.json adapter.network
    address constant SYMBIOTIC_NETWORK = 0x98e52Ea7578F2088c152E81b17A9a459bF089f2a;

    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    address constant STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    address constant ALLOCATION_MANAGER = 0x948a420b8CC1d6BFd0B6087C2E7c344a2CD0bc39;
    address constant EL_STRATEGY = 0xa4C637e0F704745D182e4D38cAb7E7485321d059;
    address constant EL_STAKER = 0x4668d41D944B92f800965266D6382EF3F5C6B763;

    string constant MAINNET_RPC_URL = "https://mainnet.gateway.tenderly.co";
    uint256 constant FORK_BLOCK = 24843127;

    DashboardLens lens;
    address stakerRewarder;

    function setUp() public {
        vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);
        lens = new DashboardLens();
        stakerRewarder = _discoverStakerRewarder(VAULT);
    }

    /// @dev Scan Symbiotic DefaultStakerRewardsFactory entities for this vault.
    function _discoverStakerRewarder(address vault) internal view returns (address rewarder) {
        address factory = 0xFEB871581C2ab2e1EEe6f7dDC7e6246cFa087A23;
        uint256 n = _totalEntities(factory);
        for (uint256 i = 0; i < n; i++) {
            address entity = _entityAt(factory, i);
            try IDefaultStakerRewards(entity).VAULT() returns (address v) {
                if (v == vault) return entity;
            } catch { }
        }
    }

    function _totalEntities(address registry) internal view returns (uint256) {
        (bool ok, bytes memory data) = registry.staticcall(abi.encodeWithSignature("totalEntities()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _entityAt(address registry, uint256 index) internal view returns (address entity) {
        (bool ok, bytes memory data) = registry.staticcall(abi.encodeWithSignature("entity(uint256)", index));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function test_fork_getSymbioticVaultSnapshot_vaultMetadata() public view {
        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT, address(0));

        assertTrue(s.collateralToken != address(0), "collateralToken");
        assertGt(bytes(s.collateralTokenSymbol).length, 0, "collateralTokenSymbol");
        assertGt(bytes(s.collateralTokenName).length, 0, "collateralTokenName");
        assertGt(s.collateralTokenDecimals, 0, "collateralTokenDecimals");
        assertGt(s.collateralTokenPrice, 0, "collateralTokenPrice");
        assertGt(s.collateralTokenPriceLastUpdated, 0, "collateralTokenPriceLastUpdated");
        assertGt(s.epochDuration, 0, "epochDuration");
        assertGt(s.currentEpoch, 0, "currentEpoch");
        assertEq(s.stakerRewards.stakerRewarder, address(0), "stakerRewards skipped");
    }

    function test_fork_getSymbioticVaultSnapshot_epochFields() public view {
        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT, address(0));

        assertGt(s.currentEpoch, 0, "currentEpoch");
        assertGt(s.epochDuration, 0, "epochDuration");
        assertGt(s.nextEpochStart, 0, "nextEpochStart");
        assertEq(s.withdrawalEpoch, s.currentEpoch + 1, "withdrawalEpoch = currentEpoch + 1");
    }

    function test_fork_getSymbioticVaultSnapshot_stakerRewards() public view {
        assertTrue(stakerRewarder != address(0), "discover stakerRewarder");

        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT, stakerRewarder);

        assertEq(s.stakerRewards.stakerRewarder, stakerRewarder);
        assertEq(s.stakerRewards.vault, VAULT);
        assertEq(s.stakerRewards.delegator, IVault(VAULT).delegator());
        assertEq(s.delegator, s.stakerRewards.delegator, "vault and stakerRewards delegator");
        assertEq(s.stakerRewards.operator, IOperatorNetworkSpecificDelegator(s.stakerRewards.delegator).operator());
        assertEq(s.stakerRewards.network, SYMBIOTIC_NETWORK);

        assertGt(s.stakerRewards.version, 0, "version");
        assertGt(s.stakerRewards.adminFeeBase, 0, "adminFeeBase");
        assertTrue(s.stakerRewards.tokens.length > 0, "active reward tokens");

        bool foundUsdc;
        for (uint256 i = 0; i < s.stakerRewards.tokens.length; i++) {
            StakerRewardsTokenSnapshot memory t = s.stakerRewards.tokens[i];
            if (t.rewardToken == USDC) {
                foundUsdc = true;
                assertEq(t.rewardsLength, IDefaultStakerRewards(stakerRewarder).rewardsLength(USDC, SYMBIOTIC_NETWORK));
                assertEq(t.tokenBalance, IERC20(USDC).balanceOf(stakerRewarder));
            }
        }
        assertTrue(foundUsdc, "USDC reward token entry");
    }

    function test_fork_getSymbioticVaultSnapshot_wrongStakerRewarder() public view {
        SymbioticVaultSnapshot memory s = lens.getSymbioticVaultSnapshot(VAULT, AGENT, address(0xdead));

        assertEq(s.stakerRewards.stakerRewarder, address(0));
        assertEq(s.stakerRewards.delegator, address(0));
        assertEq(s.stakerRewards.operator, address(0));
        assertEq(s.stakerRewards.network, address(0));
        assertEq(s.stakerRewards.tokens.length, 0);
    }

    // ─── EigenLayer Snapshot ──────────────────────────────────────────────────

    function test_fork_getEigenLayerSnapshot_callSucceeds() public view {
        EigenLayerSnapshot memory s = lens.getEigenLayerSnapshot(
            EL_STRATEGY, EL_STAKER, STRATEGY_MANAGER, DELEGATION_MANAGER, ALLOCATION_MANAGER
        );

        if (s.depositedShares == 0) {
            assertEq(s.depositedAmount, 0, "zero shares -> zero amount");
        } else {
            assertGt(s.depositedAmount, 0, "non-zero shares -> non-zero amount");
        }

        if (s.allocationDelayPending) {
            assertEq(s.allocationDelay, 0, "pending delay -> delay value is 0");
        }
    }

    function test_fork_getEigenLayerSnapshot_delegationState() public view {
        EigenLayerSnapshot memory s = lens.getEigenLayerSnapshot(
            EL_STRATEGY, EL_STAKER, STRATEGY_MANAGER, DELEGATION_MANAGER, ALLOCATION_MANAGER
        );

        assertTrue(s.isDelegated, "EL operator should be delegated");
        assertEq(s.delegatee, EL_STAKER, "EL operator should delegate to self");
    }

    // ─── Loan Snapshot ────────────────────────────────────────────────────────

    function test_fork_getLoanSnapshot_nonZeroLoan() public {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);

        assertGt(s.totalDelegation, 0, "totalDelegation");
        assertGt(s.totalSlashableCollateral, 0, "totalSlashableCollateral");
        assertGt(s.totalDebt, 0, "totalDebt");
        assertGt(s.health, 0, "health");
        assertGt(s.ltv, 0, "ltv");
        assertGt(s.liquidationThreshold, 0, "liquidationThreshold");
        assertEq(s.coverageCap, IDelegation(address(lens.DELEGATION())).coverageCap(AGENT), "coverageCap");

        (
            uint256 id,
            address vault,
            address debtToken,
            address interestReceiver,
            uint8 decimals,
            bool paused,
            uint256 minBorrow
        ) = ILender(address(lens.LENDER())).reservesData(USDC);
        assertEq(s.reserve.id, id, "reserve.id");
        assertEq(s.reserve.vault, vault, "reserve.vault");
        assertEq(s.reserve.debtToken, debtToken, "reserve.debtToken");
        assertEq(s.reserve.interestReceiver, interestReceiver, "reserve.interestReceiver");
        assertEq(s.reserve.decimals, decimals, "reserve.decimals");
        assertEq(s.reserve.paused, paused, "reserve.paused");
        assertEq(s.reserve.minBorrow, minBorrow, "reserve.minBorrow");
    }

    function test_fork_getLoanSnapshot_healthAboveOne() public {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);
        assertGt(s.health, 1e27, "health should be above 1 ray for a well-collateralised agent");
    }

    function test_fork_getLoanSnapshot_accruedInterestAndMaxBorrowable() public {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);
        assertTrue(s.accruedRestakerInterest >= 0);
        assertTrue(s.maxBorrowable >= 0);
    }

    function test_fork_getLoanSnapshot_collateralMetadata() public {
        LoanSnapshot memory s = lens.getLoanSnapshot(AGENT, USDC);

        assertTrue(s.collateralToken != address(0), "collateralToken");
        assertGt(bytes(s.collateralTokenSymbol).length, 0, "collateralTokenSymbol");
        assertGt(bytes(s.collateralTokenName).length, 0, "collateralTokenName");
        assertGt(s.collateralTokenDecimals, 0, "collateralTokenDecimals");
        assertGt(s.collateralTokenPrice, 0, "collateralTokenPrice");
        assertGt(s.collateralTokenPriceLastUpdated, 0, "collateralTokenPriceLastUpdated");
        assertGt(s.vaultAssetPrice, 0, "vaultAssetPrice");
        assertGt(s.vaultAssetPriceLastUpdated, 0, "vaultAssetPriceLastUpdated");
    }

    // ─── Agent coverage / snapshot ────────────────────────────────────────────

    function test_fork_getAgentCoverageSnapshot() public view {
        AgentCoverageSnapshot memory s = lens.getAgentCoverageSnapshot(AGENT);

        assertGt(s.epochDuration, 0, "epochDuration");
        assertEq(s.currentEpoch, IDelegation(address(lens.DELEGATION())).epoch(), "currentEpoch");
        assertEq(s.coverageCap, IDelegation(address(lens.DELEGATION())).coverageCap(AGENT), "coverageCap");
        assertGt(s.totalDelegation, 0, "totalDelegation");
        assertGt(s.liveCoverage, 0, "liveCoverage");
    }

    function test_fork_getAgentSnapshot() public {
        AgentSnapshot memory s = lens.getAgentSnapshot(AGENT);

        assertGt(s.coverage.totalDelegation, 0, "coverage.totalDelegation");
        assertGt(s.loans.length, 0, "loans.length");

        bool foundUsdc;
        for (uint256 i; i < s.loans.length; ++i) {
            if (s.loans[i].asset == USDC) {
                foundUsdc = true;
                assertGt(s.loans[i].assetPriceUSD, 0, "usdc assetPriceUSD");
            }
        }
        assertTrue(foundUsdc, "USDC reserve present");
    }

    function test_fork_getReserveSnapshots() public view {
        ReserveSnapshot[] memory snapshots = lens.getReserveSnapshots();
        assertGt(snapshots.length, 0, "reserves length");

        bool foundUsdc;
        for (uint256 i; i < snapshots.length; ++i) {
            if (snapshots[i].asset == USDC) {
                foundUsdc = true;
                assertTrue(snapshots[i].vault != address(0), "usdc vault");
                assertGt(snapshots[i].assetPriceUSD, 0, "usdc assetPriceUSD");
            }
        }
        assertTrue(foundUsdc, "USDC reserve present");
    }
}
