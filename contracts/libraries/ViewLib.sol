// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMarket } from "../interfaces/IMarket.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ViewLib
/// @author kexley
/// @notice Read-only views and math for market storage
library ViewLib {
    using WadRayMath for uint256;

    /// @notice Get the name of a market
    function name(IMarket.Storage storage $) internal view returns (string memory) {
        return $.name;
    }

    /// @notice Get the price of the asset for a market
    function getPrice(IMarket.Storage storage $) internal view returns (uint256 price) {
        (price,) = IOracle($.oracle).getPrice($.asset);
    }

    /// @notice Get the supply interest index for a market
    function supplyIndex(IMarket.Storage storage $) internal view returns (uint256 currentIndex) {
        uint256 canonicalIndex =
            $.variable ? IInterestRateModel($.irm).variableIndex() : IInterestRateModel($.irm).fixedIndex();
        currentIndex = canonicalIndex.rayMul($.multiplier);
    }

    /// @notice Get the tranche premium index for a market
    function underwriterIndex(IMarket.Storage storage $) internal view returns (uint256 currentIndex) {
        currentIndex = IInterestRateModel($.irm).underwriterIndex(address(this));
    }

    /// @notice Get the combined debt index for a market
    function index(IMarket.Storage storage $) internal view returns (uint256 currentIndex) {
        currentIndex = supplyIndex($).rayMul(underwriterIndex($));
    }

    /// @notice Get the current debt owed by the borrower
    function debt(IMarket.Storage storage $) internal view returns (uint256 marketDebt) {
        marketDebt = $.scaledDebt.rayMul(index($));
    }

    /// @notice Get the senior tranche for a market
    function seniorTranche(IMarket.Storage storage $) internal view returns (address tranche) {
        tranche = $.seniorTranche;
    }

    /// @notice Get the junior tranche for a market
    function juniorTranche(IMarket.Storage storage $) internal view returns (address tranche) {
        tranche = $.juniorTranche;
    }

    /// @notice Get the variable interest rate for a market
    function interestType(IMarket.Storage storage $) internal view returns (bool variable) {
        variable = $.variable;
    }

    /// @notice Get the multiplier for a market
    function multiplier(IMarket.Storage storage $) internal view returns (uint256 mult) {
        mult = $.multiplier;
    }

    /// @notice Get the buffer for a market
    function buffer(IMarket.Storage storage $) internal view returns (uint256 buffer_) {
        buffer_ = $.buffer;
    }

    /// @notice Get the liquidation threshold for a market
    function lt(IMarket.Storage storage $) internal view returns (uint256 lt_) {
        lt_ = $.lt;
    }

    /// @notice Get the loan to value ratio for a market
    function ltv(IMarket.Storage storage $) internal view returns (uint256 ltv_) {
        ltv_ = $.ltv;
    }

    /// @notice Get the borrow cap for a market
    function borrowCap(IMarket.Storage storage $) internal view returns (uint256 cap) {
        cap = $.borrowCap;
    }

    /// @notice Get the junior split for a market
    function juniorSplit(IMarket.Storage storage $) internal view returns (uint256 split) {
        split = $.juniorSplit;
    }

    /// @notice Get the total capital for a market
    function totalCapital(IMarket.Storage storage $) internal view returns (uint256 capital) {
        capital = (IVault($.vault).balanceOf($.seniorTranche, $.asset)
                + IVault($.vault).balanceOf($.juniorTranche, $.asset))
        .rayDiv(getPrice($));
    }

    /// @notice Get the total credit for a market
    function totalCredit(IMarket.Storage storage $) internal view returns (uint256 credit) {
        credit = totalCapital($).rayMul($.lt);
    }

    /// @notice Get the available credit for a market
    function availableCredit(IMarket.Storage storage $) internal view returns (uint256 credit) {
        uint256 availableAssets = ITranche($.seniorTranche).activeAssets() + ITranche($.juniorTranche).activeAssets();
        credit = availableAssets.rayDiv(getPrice($)).rayMul($.ltv);
    }

    /// @notice Get the utilization of a market
    function utilization(IMarket.Storage storage $) internal view returns (uint256 util) {
        uint256 credit = totalCredit($);
        if (credit == 0) return 0;
        util = debt($).rayDiv(credit);
    }

    /// @notice Get the maximum amount of cUSD that can be borrowed
    function maxBorrowable(IMarket.Storage storage $) internal view returns (uint256 borrowable) {
        uint256 totalDebt = debt($);
        uint256 remainingCredit = Math.min($.borrowCap, availableCredit($));
        borrowable = totalDebt > remainingCredit ? 0 : remainingCredit - totalDebt;
    }

    /// @notice Get the maximum amount of cUSD that can be liquidated
    function maxLiquidatable(IMarket.Storage storage $) internal view returns (uint256 liquidatable) {
        uint256 totalDebt = debt($);
        uint256 credit = totalCredit($);
        if (totalDebt > credit) {
            liquidatable = (($.targetHealth.rayMul(totalDebt) - credit).rayDiv($.targetHealth - $.lt));
            if (liquidatable > totalDebt) liquidatable = totalDebt;
        }
    }

    /// @notice Get the liquidation bonus percentage
    function bonus(IMarket.Storage storage $) internal view returns (uint256 percentage) {
        uint256 totalDebt = debt($);
        if (totalDebt == 0) return 0;

        uint256 capital = totalCapital($);
        if (totalDebt >= capital) return 0;

        uint256 health = capital.rayMul($.lt).rayDiv(totalDebt);
        if (health >= 1e27) return 0;

        if (health > $.bonusKink) {
            percentage = $.bonusSlope0.rayMul(1e27 - health).rayDiv(1e27 - $.bonusKink);
        } else {
            percentage = $.bonusSlope0 + $.bonusSlope1.rayMul($.bonusKink - health).rayDiv($.bonusKink);
        }

        uint256 maxBonus = (capital - totalDebt).rayDiv(totalDebt);
        if (percentage > maxBonus) percentage = maxBonus;
    }

    /// @notice Get locked collateral for an underwriter tranche
    function lockedAssets(IMarket.Storage storage $, address underwriter) internal view returns (uint256 assets) {
        assets = debt($).rayDiv($.lt - $.buffer).rayMul(getPrice($));
        if (underwriter == $.seniorTranche) {
            uint256 juniorAssets = IVault($.vault).balanceOf($.juniorTranche, $.asset);
            assets = assets > juniorAssets ? assets - juniorAssets : 0;
        }
    }

    /// @notice Get the claimable reward for a tranche
    /// @param tranche The tranche to get the claimable reward for
    /// @return reward The amount of claimable reward
    function claimable(IMarket.Storage storage $, address tranche) external view returns (uint256 reward) {
        reward = $.reward[tranche];
        if ($.lastRewardUpdate != block.timestamp) {
            uint256 supply = ITranche(tranche).activeSupply();
            if (supply == 0) return reward;

            uint256 supplyIndex = supplyIndex($);
            uint256 underwriterIndex = underwriterIndex($);
            uint256 scaledDebt = $.scaledDebt;
            uint256 premiumInterest = scaledDebt.rayMul(supplyIndex.rayMul(underwriterIndex - $.lastUnderwriterIndex));

            uint256 juniorInterest = premiumInterest.rayMul($.juniorSplit);
            if (tranche == $.seniorTranche) {
                reward += premiumInterest - juniorInterest;
            } else if (tranche == $.juniorTranche) {
                reward += juniorInterest;
            }
        }
    }
}
