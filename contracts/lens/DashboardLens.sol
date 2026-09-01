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

/// @dev Cap vault + minter surface used by reserve snapshots (avoids clashing with Symbiotic IVault).
interface ICapVaultLens {
    function totalSupplies(address asset) external view returns (uint256 totalSupply);
    function totalBorrows(address asset) external view returns (uint256 totalBorrow);
    function depositCap(address asset) external view returns (uint256 cap);
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

struct LoanReserveSnapshot {
    uint256 id;
    address vault;
    address debtToken;
    address interestReceiver;
    uint8 decimals;
    bool paused;
    uint256 minBorrow;
}

struct LoanSnapshot {
    uint256 totalDelegation;
    uint256 totalSlashableCollateral;
    /// @dev Coverage cap in USD (8 decimals) — matches IDelegation.coverageCap.
    uint256 coverageCap;
    LoanReserveSnapshot reserve;
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

/// @dev Coverage / epoch-boundary reads used to derive when a pending deposit becomes live.
///      Amounts are USD (8 decimals), matching IDelegation / ISymbioticNetworkMiddleware.
struct AgentCoverageSnapshot {
    uint256 totalDelegation; // MIDDLEWARE.coverage(agent)
    uint256 liveCoverage; // DELEGATION.coverage(agent)
    uint256 coverageCap; // DELEGATION.coverageCap(agent)
    uint256 slashableAtCurrentEpochStart; // MIDDLEWARE.slashableCollateral(agent, epoch*dur)
    uint256 slashableAtPrevEpochStart; // MIDDLEWARE.slashableCollateral(agent, (epoch-1)*dur)
    uint256 currentEpoch;
    uint256 epochDuration;
}

/// @dev Per-reserve loan slice for the lean agent list/summary view.
struct AgentLoan {
    address asset;
    uint256 debt; // LENDER.debt(agent, asset)
    uint256 accruedRestakerInterest; // LENDER.accruedRestakerInterest(agent, asset)
    uint256 maxBorrowable; // LENDER.maxBorrowable(agent, asset)
    uint256 assetPriceUSD; // PRICE_ORACLE.getPrice(asset)
    /// @dev Rates in ray (27 decimals). Spec put these on AgentSnapshot, but the oracles take an
    ///      asset — they live here so multi-reserve agents stay correct.
    uint256 marketRate;
    uint256 benchmarkRate;
    uint256 utilizationRate;
}

/// @dev Lean per-agent snapshot for summary/list pages (no strings / lastUpdated).
struct AgentSnapshot {
    AgentCoverageSnapshot coverage;
    uint256 restakerRate; // RATE_ORACLE.restakerRate(agent)
    AgentLoan[] loans; // one entry per hardcoded reserve asset
}

/// @dev Lean per-reserve snapshot for the lender-assets summary page.
struct ReserveSnapshot {
    address asset;
    address vault;
    uint256 totalSupplies; // VAULT.totalSupplies(asset)
    uint256 totalBorrows; // VAULT.totalBorrows(asset)
    uint256 depositCap; // VAULT.depositCap(asset)
    uint256 assetPriceUSD; // PRICE_ORACLE.getPrice(asset)
    uint256 minBorrow; // LENDER.reservesData(asset).minBorrow
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
    /// @dev Hardcoded borrowable reserves (Lender has no reservesList getter we can upgrade).
    address internal constant MAINNET_WWTGXX = 0x434558CB1EBe9950e8A66f1ef8A15A473Dce7D8c;

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

    // ─── Agent coverage ──────────────────────────────────────────────────────

    /// @notice Returns coverage + epoch-boundary slashable collateral for an agent.
    /// @dev Resolves the agent's middleware via `DELEGATION.networks(agent)`, falling back to
    ///      `SYMBIOTIC_NETWORK_MIDDLEWARE`. Per-read reverts are swallowed (zeroed) so this is
    ///      safe inside an `allowFailure:false` multicall. Epoch-start timestamps mirror
    ///      `Delegation.coverage()` (subtract 1 when equal to `block.timestamp`).
    function getAgentCoverageSnapshot(address agent) external view returns (AgentCoverageSnapshot memory s) {
        return _agentCoverageSnapshot(agent);
    }

    /// @notice Lean per-agent snapshot for summary/list pages: coverage + restaker rate + per-reserve loans.
    /// @dev Walks the hardcoded reserve asset list. Zero-fills failed reads.
    ///      Not `view`: IRateOracle.marketRate / utilizationRate are non-view (adapter calls).
    function getAgentSnapshot(address agent) external returns (AgentSnapshot memory s) {
        s.coverage = _agentCoverageSnapshot(agent);

        try RATE_ORACLE.restakerRate(agent) returns (uint256 rate) {
            s.restakerRate = rate;
        } catch { }

        address[] memory assets = _reserveAssets();
        s.loans = new AgentLoan[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            s.loans[i] = _agentLoan(agent, assets[i]);
        }
    }

    /// @notice Lean per-reserve snapshots for the lender-assets summary page.
    /// @dev Walks the hardcoded reserve asset list. Zero-fills failed reads.
    function getReserveSnapshots() external view returns (ReserveSnapshot[] memory snapshots) {
        address[] memory assets = _reserveAssets();
        snapshots = new ReserveSnapshot[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            snapshots[i] = _reserveSnapshot(assets[i]);
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

        try LENDER.reservesData(asset) returns (
            uint256 id,
            address vault,
            address debtToken,
            address interestReceiver,
            uint8 decimals,
            bool paused,
            uint256 minBorrow
        ) {
            snapshot.reserve.id = id;
            snapshot.reserve.vault = vault;
            snapshot.reserve.debtToken = debtToken;
            snapshot.reserve.interestReceiver = interestReceiver;
            snapshot.reserve.decimals = decimals;
            snapshot.reserve.paused = paused;
            snapshot.reserve.minBorrow = minBorrow;
        } catch { }
    }

    // ─── Agent / reserve helpers (internal) ──────────────────────────────────

    function _agentCoverageSnapshot(address agent) internal view returns (AgentCoverageSnapshot memory s) {
        uint256 dur = DELEGATION.epochDuration();
        uint256 epoch = DELEGATION.epoch();
        s.currentEpoch = epoch;
        s.epochDuration = dur;

        uint48 curStart = uint48(epoch * dur);
        if (curStart == block.timestamp) curStart -= 1;
        uint48 prevStart = uint48(epoch > 0 ? (epoch - 1) * dur : 0);

        ISymbioticNetworkMiddleware middleware = SYMBIOTIC_NETWORK_MIDDLEWARE;
        try DELEGATION.networks(agent) returns (address network) {
            if (network != address(0)) middleware = ISymbioticNetworkMiddleware(network);
        } catch { }

        try DELEGATION.coverageCap(agent) returns (uint256 cap) {
            s.coverageCap = cap;
        } catch { }

        try middleware.coverage(agent) returns (uint256 coverage) {
            s.totalDelegation = coverage;
        } catch { }

        try DELEGATION.coverage(agent) returns (uint256 coverage) {
            s.liveCoverage = coverage;
        } catch { }

        try middleware.slashableCollateral(agent, curStart) returns (uint256 slashable) {
            s.slashableAtCurrentEpochStart = slashable;
        } catch { }

        try middleware.slashableCollateral(agent, prevStart) returns (uint256 slashable) {
            s.slashableAtPrevEpochStart = slashable;
        } catch { }
    }

    function _reserveAssets() internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = MAINNET_USDC;
        assets[1] = MAINNET_WWTGXX;
    }

    function _agentLoan(address agent, address asset) internal returns (AgentLoan memory loan) {
        loan.asset = asset;

        try LENDER.debt(agent, asset) returns (uint256 debt) {
            loan.debt = debt;
        } catch { }

        try LENDER.accruedRestakerInterest(agent, asset) returns (uint256 interest) {
            loan.accruedRestakerInterest = interest;
        } catch { }

        try LENDER.maxBorrowable(agent, asset) returns (uint256 maxBorrow) {
            loan.maxBorrowable = maxBorrow;
        } catch { }

        try PRICE_ORACLE.getPrice(asset) returns (uint256 price, uint256) {
            loan.assetPriceUSD = price;
        } catch { }

        try RATE_ORACLE.marketRate(asset) returns (uint256 rate) {
            loan.marketRate = rate;
        } catch { }

        try RATE_ORACLE.benchmarkRate(asset) returns (uint256 rate) {
            loan.benchmarkRate = rate;
        } catch { }

        try RATE_ORACLE.utilizationRate(asset) returns (uint256 rate) {
            loan.utilizationRate = rate;
        } catch { }
    }

    function _reserveSnapshot(address asset) internal view returns (ReserveSnapshot memory s) {
        s.asset = asset;

        address vault;
        try LENDER.reservesData(asset) returns (
            uint256, address vaultAddr, address, address, uint8, bool, uint256 minBorrow
        ) {
            vault = vaultAddr;
            s.vault = vaultAddr;
            s.minBorrow = minBorrow;
        } catch { }

        if (vault != address(0)) {
            ICapVaultLens v = ICapVaultLens(vault);
            try v.totalSupplies(asset) returns (uint256 supplies) {
                s.totalSupplies = supplies;
            } catch { }
            try v.totalBorrows(asset) returns (uint256 borrows) {
                s.totalBorrows = borrows;
            } catch { }
            try v.depositCap(asset) returns (uint256 cap) {
                s.depositCap = cap;
            } catch { }
        }

        try PRICE_ORACLE.getPrice(asset) returns (uint256 price, uint256) {
            s.assetPriceUSD = price;
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
