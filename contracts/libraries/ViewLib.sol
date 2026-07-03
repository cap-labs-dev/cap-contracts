// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ViewLib
/// @author kexley
/// @notice Read-only views and math. Functions are internal and operate on a storage pointer so they
/// inline into both the Lend and Reward libraries.
library ViewLib {
    using WadRayMath for uint256;

    /// @notice Get the price of the asset for a market
    function getPrice(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 price) {
        (price,) = IOracle($.oracle).getPrice($.market[marketId].asset);
    }

    /// @notice Get the supply interest index for a market
    function supplyIndex(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 currentIndex) {
        ILender.Market storage market = $.market[marketId];
        currentIndex =
            market.variable ? IInterestRateModel($.irm).variableIndex() : IInterestRateModel($.irm).fixedIndex();
        uint256 mult = market.multiplier;
        currentIndex = 1e27 + currentIndex.rayMul(mult) - mult;
    }

    /// @notice Get the tranche premium index for a market
    function trancheIndex(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 currentIndex) {
        currentIndex = IInterestRateModel($.irm).index(marketId);
    }

    /// @notice Get the combined debt index for a market
    function index(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 currentIndex) {
        currentIndex = supplyIndex($, marketId).rayMul(trancheIndex($, marketId));
    }

    /// @notice Get the scaled debt for a market
    function scaledDebt(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 sDebt) {
        sDebt = $.market[marketId].scaledDebt;
    }

    /// @notice Get the current debt owed by the borrower
    function debt(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 marketDebt) {
        marketDebt = $.market[marketId].scaledDebt.rayMul(index($, marketId));
    }

    /// @notice Get the total capital for a market
    function totalCapital(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 capital) {
        ILender.Market storage market = $.market[marketId];
        capital = (IVault($.vault).balanceOf(market.seniorTranche, market.asset)
                + IVault($.vault).balanceOf(market.juniorTranche, market.asset))
        .rayDiv(getPrice($, marketId));
    }

    /// @notice Get the total credit for a market
    function totalCredit(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 credit) {
        credit = totalCapital($, marketId).rayMul($.market[marketId].lt);
    }

    /// @notice Get the available credit for a market
    function availableCredit(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 credit) {
        ILender.Market storage market = $.market[marketId];
        uint256 availableAssets =
            ITranche(market.seniorTranche).activeAssets() + ITranche(market.juniorTranche).activeAssets();
        credit = availableAssets.rayDiv(getPrice($, marketId)).rayMul(market.ltv);
    }

    /// @notice Get the utilization of a market
    function utilization(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 util) {
        uint256 credit = totalCredit($, marketId);
        if (credit == 0) return 0;
        util = debt($, marketId).rayDiv(credit);
    }

    /// @notice Get the borrow cap for a market
    function borrowCap(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 cap) {
        cap = $.market[marketId].borrowCap;
    }

    /// @notice Get the maximum amount of cUSD that can be borrowed
    function maxBorrowable(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 borrowable) {
        ILender.Market storage market = $.market[marketId];
        uint256 totalDebt = debt($, marketId);
        uint256 remainingCredit = Math.min(market.borrowCap, availableCredit($, marketId));
        borrowable = totalDebt > remainingCredit ? 0 : remainingCredit - totalDebt;
    }

    /// @notice Get the maximum amount of cUSD that can be liquidated
    function maxLiquidatable(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 liquidatable) {
        ILender.Market storage market = $.market[marketId];
        uint256 totalDebt = debt($, marketId);
        uint256 credit = totalCredit($, marketId);
        if (totalDebt > credit) {
            liquidatable = (($.targetHealth.rayMul(totalDebt) - credit).rayDiv($.targetHealth - market.lt));
            if (liquidatable > totalDebt) liquidatable = totalDebt;
        }
    }

    /// @notice Get the liquidation bonus percentage
    function getBonus(ILender.Storage storage $, bytes32 marketId) internal view returns (uint256 bonus) {
        ILender.Market storage market = $.market[marketId];
        uint256 totalDebt = debt($, marketId);
        if (totalDebt == 0) return 0;

        uint256 capital = totalCapital($, marketId);
        if (totalDebt >= capital) return 0;

        uint256 health = capital.rayMul(market.lt).rayDiv(totalDebt);
        if (health >= 1e27) return 0;

        if (health > $.bonusKink) {
            bonus = $.bonusSlope0.rayMul(1e27 - health).rayDiv(1e27 - $.bonusKink);
        } else {
            bonus = $.bonusSlope0 + $.bonusSlope1.rayMul($.bonusKink - health).rayDiv($.bonusKink);
        }

        uint256 maxBonus = (capital - totalDebt).rayDiv(totalDebt);
        if (bonus > maxBonus) bonus = maxBonus;
    }

    /// @notice Get locked collateral for an underwriter tranche
    function lockedAssets(ILender.Storage storage $, bytes32 marketId, address underwriter)
        internal
        view
        returns (uint256 assets)
    {
        ILender.Market storage market = $.market[marketId];
        assets = debt($, marketId).rayDiv(market.lt - market.buffer).rayMul(getPrice($, marketId));
        if (underwriter == market.seniorTranche) {
            uint256 juniorAssets = IVault($.vault).balanceOf(market.juniorTranche, market.asset);
            assets = assets > juniorAssets ? assets - juniorAssets : 0;
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Rewarder views ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Get the claimable supply reward
    function claimableSupplyReward(ILender.Storage storage $) internal view returns (uint256 reward) {
        reward = $.supplyReward;
    }

    /// @notice Get the claimable tranche reward
    function claimableTrancheReward(ILender.Storage storage $, address tranche, address user)
        internal
        view
        returns (uint256 reward)
    {
        bytes32 marketId = $.marketForTranche[tranche];
        ILender.Market storage market = $.market[marketId];
        reward = market.pendingReward[tranche][user]
            + rewardPerShare($, tranche).rayMul(IERC20(tranche).balanceOf(user)) - market.rewardDebt[tranche][user];
    }

    /// @notice Get the accumulated reward per share for an underwriter tranche
    function rewardPerShare(ILender.Storage storage $, address tranche)
        internal
        view
        returns (uint256 accRewardPerShare)
    {
        bytes32 marketId = $.marketForTranche[tranche];
        ILender.Market storage market = $.market[marketId];
        accRewardPerShare = market.rewardPerShare[tranche];

        uint256 currentSupplyIndex = supplyIndex($, marketId);
        uint256 currentTrancheIndex = trancheIndex($, marketId);
        uint256 sDebt = scaledDebt($, marketId);
        uint256 supply = ITranche(tranche).activeSupply();

        if (sDebt > 0 && supply > 0 && market.lastIndexUpdate != block.timestamp) {
            uint256 premiumInterest =
                sDebt.rayMul(currentSupplyIndex.rayMul(currentTrancheIndex - market.lastTrancheIndex));

            bool isJunior = tranche == market.juniorTranche;
            address other = isJunior ? market.seniorTranche : market.juniorTranche;
            uint256 share = ITranche(other).activeSupply() == 0
                ? 1e27
                : (isJunior ? market.juniorSplit : 1e27 - market.juniorSplit);
            uint256 trancheInterest = premiumInterest.rayMul(share);
            if (trancheInterest > 0) accRewardPerShare += trancheInterest.rayDiv(supply);
        }
    }

    /// @notice Check if an address is a tranche
    /// @param tranche The address to check
    /// @return isTranche Whether the address is a tranche
    function isTranche(ILender.Storage storage $, address tranche) internal view returns (bool) {
        return $.marketForTranche[tranche] != bytes32(0);
    }
}
