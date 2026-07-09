// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IMarket } from "../interfaces/IMarket.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { ViewLib } from "./ViewLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RewardLib
/// @author kexley
/// @notice Reward accrual and claims.
library RewardLib {
    using WadRayMath for uint256;

    /// @notice Accrue rewards for a market
    function updateRewards(IMarket.Storage storage $) public {
        if ($.lastRewardUpdate == block.timestamp) return;

        uint256 supplyIndex = ViewLib.supplyIndex($);
        uint256 underwriterIndex = ViewLib.underwriterIndex($);
        uint256 scaledDebt = $.scaledDebt;

        if (scaledDebt > 0) {
            uint256 supplyInterest = scaledDebt.rayMul($.lastSupplyIndex.rayMul(supplyIndex - $.lastSupplyIndex));
            uint256 premiumInterest = scaledDebt.rayMul(supplyIndex.rayMul(underwriterIndex - $.lastUnderwriterIndex));
            uint256 juniorInterest = premiumInterest.rayMul($.juniorSplit);
            uint256 seniorInterest = premiumInterest - juniorInterest;
            uint256 seniorSupply = ITranche($.seniorTranche).activeSupply();
            uint256 juniorSupply = ITranche($.juniorTranche).activeSupply();

            if (supplyInterest > 0) IStablecoin($.stablecoin).mintUnbacked($.stablecoinYield, supplyInterest);
            if (seniorInterest > 0 && seniorSupply > 0) $.reward[$.seniorTranche] += seniorInterest;
            if (juniorInterest > 0 && juniorSupply > 0) $.reward[$.juniorTranche] += juniorInterest;
        }

        $.lastSupplyIndex = supplyIndex;
        $.lastUnderwriterIndex = underwriterIndex;
        $.lastRewardUpdate = block.timestamp;
    }

    /// @notice Claim the reward for a tranche
    /// @return reward The amount of reward claimed
    function claim(IMarket.Storage storage $) external returns (uint256 reward) {
        address tranche = msg.sender;
        if (tranche != $.seniorTranche && tranche != $.juniorTranche) revert IMarket.InvalidTranche();

        updateRewards($);
        reward = $.reward[tranche];
        $.reward[tranche] = 0;
        IStablecoin($.stablecoin).mintUnbacked(tranche, reward);
        emit IMarket.Claimed(tranche, reward);
    }
}
