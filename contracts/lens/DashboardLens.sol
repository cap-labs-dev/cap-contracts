// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDelegation } from "../interfaces/IDelegation.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IRateOracle } from "../interfaces/IRateOracle.sol";
import { ISymbioticNetworkMiddleware } from "../interfaces/ISymbioticNetworkMiddleware.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import {
    IOperatorNetworkSpecificDelegator
} from "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import {
    IDefaultStakerRewards
} from "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDelegationManager } from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import { IStrategy } from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import { IStrategyManager } from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";

// ─── Residual Local Interfaces ────────────────────────────────────────────────

interface IAllocationManagerLens {
    function getAllocationDelay(address operator) external view returns (bool isSet, uint32 delay);
}

// ─── Structs ─────────────────────────────────────────────────────────────────

struct StakerRewardsTokenSnapshot {
    address rewardToken;
    uint256 tokenBalance;
    uint256 claimableAdminFee;
    uint256 rewardsLength;
}

struct StakerRewardsSnapshot {
    address stakerRewarder;
    address delegator;
    address operator;
    address vault;
    address network;
    uint64 version;
    uint256 adminFee;
    uint256 adminFeeBase;
    StakerRewardsTokenSnapshot[] tokens;
}

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
    string collateralTokenSymbol;
    string collateralTokenName;
    uint256 collateralTokenDecimals;
    uint256 collateralTokenPrice;
    uint256 collateralTokenPriceLastUpdated;
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
    StakerRewardsSnapshot stakerRewards;
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
    /// @dev Coverage cap in USD (8 decimals) — matches IDelegation.coverageCap.
    uint256 coverageCap;
    uint256 totalDebt;
    uint256 ltv;
    uint256 liquidationThreshold;
    uint256 health;
    uint256 accruedRestakerInterest;
    uint256 maxBorrowable;
    /// @dev Rates in ray (27 decimals), yearly — matches IRateOracle / DebtToken interest logic.
    uint256 benchmarkRate;
    uint256 marketRate;
    uint256 utilizationRate;
    uint256 restakerRate;
    /// @dev max(marketRate, benchmarkRate) + utilizationRate, same as DebtToken._nextInterestRate.
    uint256 borrowRate;
    /// @dev Price and lastUpdated from IPriceOracle.getPrice (8-decimal USD convention).
    uint256 vaultAssetPrice;
    uint256 vaultAssetPriceLastUpdated;
    address collateralToken;
    string collateralTokenSymbol;
    string collateralTokenName;
    uint256 collateralTokenDecimals;
    uint256 collateralTokenPrice;
    uint256 collateralTokenPriceLastUpdated;
}

// ─── DashboardLens ───────────────────────────────────────────────────────────

/// @title DashboardLens
/// @notice Read-only aggregation contract for the CAP Underwriter Dashboard.
///         Batches multiple external contract reads into a single call to reduce
///         RPC round-trips and avoid rate limiting.
/// @dev No state, no write functions, no access control — purely an aggregation utility.
///      Some reads use non-view oracle rate functions; callers should use eth_call.
contract DashboardLens {
    ILender public constant LENDER = ILender(0x15622c3dbbc5614E6DFa9446603c1779647f01FC);
    IOptInService public constant VAULT_OPT_IN_SERVICE = IOptInService(0xb361894bC06cbBA7Ea8098BF0e32EB1906A5F891);
    IDelegation public constant DELEGATION = IDelegation(0xF3E3Eae671000612CE3Fd15e1019154C1a4d693F);
    IRateOracle public constant RATE_ORACLE = IRateOracle(0xcD7f45566bc0E7303fB92A93969BB4D3f6e662bb);
    IPriceOracle public constant PRICE_ORACLE = IPriceOracle(0xcD7f45566bc0E7303fB92A93969BB4D3f6e662bb);
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    ISymbioticNetworkMiddleware public constant SYMBIOTIC_NETWORK_MIDDLEWARE =
        ISymbioticNetworkMiddleware(0x09A3976d8D63728d20DCDFEe1e531C206Ba91225);

    // ─── Symbiotic ───────────────────────────────────────────────────────────

    /// @notice Returns a snapshot of a single Symbiotic vault for a given depositor.
    /// @param vault           The Symbiotic vault contract address.
    /// @param depositor       The address whose balance and withdrawal state to read.
    /// @param stakerRewarder  DefaultStakerRewards for this vault (`0` skips `stakerRewards`).
    function getSymbioticVaultSnapshot(address vault, address depositor, address stakerRewarder)
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
        if (snapshot.collateralToken != address(0)) {
            snapshot.collateralTokenSymbol = IERC20Metadata(snapshot.collateralToken).symbol();
            snapshot.collateralTokenName = IERC20Metadata(snapshot.collateralToken).name();
            snapshot.collateralTokenDecimals = IERC20Metadata(snapshot.collateralToken).decimals();
            (snapshot.collateralTokenPrice, snapshot.collateralTokenPriceLastUpdated) =
                PRICE_ORACLE.getPrice(snapshot.collateralToken);
        }

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

        snapshot.stakerRewards = _stakerRewardsSnapshot(vault, stakerRewarder);
    }

    // ─── EigenLayer ──────────────────────────────────────────────────────────

    /// @notice Returns a snapshot of a single EigenLayer strategy for a given staker.
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

        if (snapshot.delegatee != address(0)) {
            (bool isSet, uint32 delay) =
                IAllocationManagerLens(allocationManager).getAllocationDelay(snapshot.delegatee);
            snapshot.allocationDelayPending = !isSet;
            snapshot.allocationDelay = delay;
        }
    }

    // ─── CAP Lender ──────────────────────────────────────────────────────────

    /// @notice Returns a comprehensive snapshot of a CAP loan position.
    /// @dev Not `view`: IRateOracle.marketRate / utilizationRate are non-view (adapter calls).
    function getLoanSnapshot(address agent, address asset) external returns (LoanSnapshot memory snapshot) {
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
        try LENDER.accruedRestakerInterest(agent, asset) returns (uint256 interest) {
            snapshot.accruedRestakerInterest = interest;
        } catch {
            snapshot.accruedRestakerInterest = 0;
        }
        try LENDER.maxBorrowable(agent, asset) returns (uint256 maxBorrow) {
            snapshot.maxBorrowable = maxBorrow;
        } catch {
            snapshot.maxBorrowable = 0;
        }

        try RATE_ORACLE.benchmarkRate(asset) returns (uint256 r) {
            snapshot.benchmarkRate = r;
        } catch { }

        try RATE_ORACLE.marketRate(asset) returns (uint256 r) {
            snapshot.marketRate = r;
        } catch { }

        try RATE_ORACLE.utilizationRate(asset) returns (uint256 r) {
            snapshot.utilizationRate = r;
        } catch { }

        try RATE_ORACLE.restakerRate(agent) returns (uint256 r) {
            snapshot.restakerRate = r;
        } catch { }

        uint256 base = snapshot.marketRate > snapshot.benchmarkRate ? snapshot.marketRate : snapshot.benchmarkRate;
        snapshot.borrowRate = base + snapshot.utilizationRate;

        try PRICE_ORACLE.getPrice(asset) returns (uint256 price, uint256 lastUpdated) {
            snapshot.vaultAssetPrice = price;
            snapshot.vaultAssetPriceLastUpdated = lastUpdated;
        } catch { }

        try DELEGATION.collateral(agent) returns (address collateral) {
            if (collateral != address(0)) {
                snapshot.collateralToken = collateral;
                snapshot.collateralTokenSymbol = IERC20Metadata(collateral).symbol();
                snapshot.collateralTokenName = IERC20Metadata(collateral).name();
                snapshot.collateralTokenDecimals = IERC20Metadata(collateral).decimals();
                (snapshot.collateralTokenPrice, snapshot.collateralTokenPriceLastUpdated) =
                    PRICE_ORACLE.getPrice(collateral);
                try PRICE_ORACLE.getPrice(collateral) returns (uint256 price, uint256 lastUpdated) {
                    snapshot.collateralTokenPrice = price;
                    snapshot.collateralTokenPriceLastUpdated = lastUpdated;
                } catch { }
            }
        } catch { }

        try DELEGATION.coverageCap(agent) returns (uint256 cap) {
            snapshot.coverageCap = cap;
        } catch { }
    }

    // ─── Staker rewards (internal) ─────────────────────────────────────────

    function _rewardTokenCandidates(address vault) internal view returns (address[] memory tokens, uint256 len) {
        tokens = new address[](8);
        len = 0;

        address collateral = IVault(vault).collateral();
        if (collateral != address(0)) {
            tokens[len++] = collateral;
        }
        if (collateral != MAINNET_USDC) {
            tokens[len++] = MAINNET_USDC;
        }
    }

    function _isValidCandidate(address stakerRewarder, address network, address token) internal view returns (bool) {
        if (token == address(0)) return false;

        try IERC20(token).balanceOf(stakerRewarder) returns (uint256 bal) {
            if (bal > 0) return true;
        } catch { }

        try IDefaultStakerRewards(stakerRewarder).claimableAdminFee(token) returns (uint256 fee) {
            if (fee > 0) return true;
        } catch { }

        if (network != address(0)) {
            try IDefaultStakerRewards(stakerRewarder).rewardsLength(token, network) returns (uint256 length) {
                if (length > 0) return true;
            } catch { }
        }

        return false;
    }

    function _fillTokenSnapshot(
        StakerRewardsTokenSnapshot memory t,
        address stakerRewarder,
        address network,
        address token
    ) internal view {
        t.rewardToken = token;

        try IERC20(token).balanceOf(stakerRewarder) returns (uint256 bal) {
            t.tokenBalance = bal;
        } catch { }

        try IDefaultStakerRewards(stakerRewarder).claimableAdminFee(token) returns (uint256 fee) {
            t.claimableAdminFee = fee;
        } catch { }

        if (network != address(0)) {
            try IDefaultStakerRewards(stakerRewarder).rewardsLength(token, network) returns (uint256 length) {
                t.rewardsLength = length;
            } catch { }
        }
    }

    function _stakerRewardsSnapshot(address vault, address stakerRewarder)
        internal
        view
        returns (StakerRewardsSnapshot memory s)
    {
        if (stakerRewarder == address(0) || stakerRewarder.code.length == 0) return s;

        try IDefaultStakerRewards(stakerRewarder).VAULT() returns (address v) {
            if (v != vault) return s;
        } catch {
            return s;
        }

        s.stakerRewarder = stakerRewarder;
        s.vault = vault;

        try IVault(vault).delegator() returns (address d) {
            s.delegator = d;
        } catch { }

        try IOperatorNetworkSpecificDelegator(s.delegator).operator() returns (address o) {
            s.operator = o;
        } catch { }

        try SYMBIOTIC_NETWORK_MIDDLEWARE.subnetwork(s.operator) returns (bytes32 sub) {
            s.network = Subnetwork.network(sub);
        } catch { }

        try IDefaultStakerRewards(stakerRewarder).version() returns (uint64 ver) {
            s.version = ver;
        } catch { }

        try IDefaultStakerRewards(stakerRewarder).adminFee() returns (uint256 fee) {
            s.adminFee = fee;
        } catch { }

        try IDefaultStakerRewards(stakerRewarder).ADMIN_FEE_BASE() returns (uint256 base) {
            s.adminFeeBase = base;
        } catch { }

        (address[] memory candidates, uint256 candidateLen) = _rewardTokenCandidates(vault);

        uint256 tokenCount;
        for (uint256 i = 0; i < candidateLen; i++) {
            if (_isValidCandidate(stakerRewarder, s.network, candidates[i])) tokenCount++;
        }

        if (tokenCount == 0) return s;

        s.tokens = new StakerRewardsTokenSnapshot[](tokenCount);
        uint256 j;
        for (uint256 i = 0; i < candidateLen; i++) {
            address token = candidates[i];
            if (!_isValidCandidate(stakerRewarder, s.network, token)) continue;

            _fillTokenSnapshot(s.tokens[j], stakerRewarder, s.network, token);
            j++;
        }
    }
}
