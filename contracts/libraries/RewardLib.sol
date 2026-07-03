// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { ViewLib } from "./ViewLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RewardLib
/// @author kexley
/// @notice Reward accrual, reward-debt accounting, and claims.
library RewardLib {
    using WadRayMath for uint256;
    using ViewLib for ILender.Storage;

    event ClaimSupplyReward(uint256 reward);
    event ClaimTrancheReward(address tranche, address recipient, uint256 reward);

    /// @notice Accrue rewards for a market
    function updateRewards(ILender.Storage storage $, bytes32 marketId) public {
        ILender.Market storage market = $.market[marketId];
        if (market.lastIndexUpdate == block.timestamp) return;

        uint256 supplyIndex = $.supplyIndex(marketId);
        uint256 trancheIndex = $.trancheIndex(marketId);
        uint256 scaledDebt = $.scaledDebt(marketId);

        if (scaledDebt > 0) {
            uint256 supplyInterest =
                scaledDebt.rayMul(market.lastTrancheIndex.rayMul(supplyIndex - market.lastSupplyIndex));
            uint256 premiumInterest = scaledDebt.rayMul(supplyIndex.rayMul(trancheIndex - market.lastTrancheIndex));

            if (supplyInterest > 0) $.supplyReward += supplyInterest;

            uint256 juniorInterest = premiumInterest.rayMul(market.juniorSplit);
            uint256 seniorInterest = premiumInterest - juniorInterest;

            uint256 seniorSupply = ITranche(market.seniorTranche).activeSupply();
            uint256 juniorSupply = ITranche(market.juniorTranche).activeSupply();

            if (seniorInterest > 0) {
                if (seniorSupply > 0) {
                    market.rewardPerShare[market.seniorTranche] += seniorInterest.rayDiv(seniorSupply);
                } else if (juniorSupply > 0) {
                    market.rewardPerShare[market.juniorTranche] += seniorInterest.rayDiv(juniorSupply);
                } else {
                    $.supplyReward += seniorInterest;
                }
            }

            if (juniorInterest > 0) {
                if (juniorSupply > 0) {
                    market.rewardPerShare[market.juniorTranche] += juniorInterest.rayDiv(juniorSupply);
                } else if (seniorSupply > 0) {
                    market.rewardPerShare[market.seniorTranche] += juniorInterest.rayDiv(seniorSupply);
                } else {
                    $.supplyReward += juniorInterest;
                }
            }
        }

        market.lastSupplyIndex = supplyIndex;
        market.lastTrancheIndex = trancheIndex;
        market.lastIndexUpdate = block.timestamp;
    }

    /// @notice Update the supply index for a market
    function updateSupplyIndex(ILender.Storage storage $, bytes32 marketId) public {
        $.market[marketId].lastSupplyIndex = $.supplyIndex(marketId);
    }

    /// @notice Increase reward debt for a user (tranche only)
    function increaseRewardDebt(ILender.Storage storage $, bytes32 marketId, address user, uint256 amount) public {
        ILender.Market storage market = $.market[marketId];
        if (msg.sender != market.juniorTranche && msg.sender != market.seniorTranche) {
            revert ILender.Unauthorized();
        }

        updateRewards($, marketId);
        IInterestRateModel($.irm).update(marketId);
        uint256 accRewardPerShare = $.rewardPerShare(msg.sender);
        uint256 balance = IERC20(msg.sender).balanceOf(user);
        market.pendingReward[msg.sender][user] += accRewardPerShare.rayMul(balance)
        - market.rewardDebt[msg.sender][user];
        market.rewardDebt[msg.sender][user] = accRewardPerShare.rayMul(balance + amount);
    }

    /// @notice Decrease reward debt for a user (tranche only)
    function decreaseRewardDebt(ILender.Storage storage $, bytes32 marketId, address user, uint256 amount) public {
        ILender.Market storage market = $.market[marketId];
        if (msg.sender != market.juniorTranche && msg.sender != market.seniorTranche) {
            revert ILender.Unauthorized();
        }

        updateRewards($, marketId);
        IInterestRateModel($.irm).update(marketId);
        uint256 accRewardPerShare = $.rewardPerShare(msg.sender);
        uint256 balance = IERC20(msg.sender).balanceOf(user);
        market.pendingReward[msg.sender][user] += accRewardPerShare.rayMul(balance)
        - market.rewardDebt[msg.sender][user];
        market.rewardDebt[msg.sender][user] = accRewardPerShare.rayMul(balance - amount);
    }

    /// @notice Claim accumulated supply interest as stcUSD
    function claimSupplyReward(ILender.Storage storage $) public returns (uint256 reward) {
        reward = $.supplyReward;
        $.supplyReward = 0;
        IStablecoin($.stablecoin).mintUnbacked($.stcUSD, reward);
        emit ClaimSupplyReward(reward);
    }

    /// @notice Mint underwriter premium rewards to a recipient
    function claimTrancheReward(ILender.Storage storage $, address tranche, address recipient)
        public
        returns (uint256 reward)
    {
        bytes32 marketId = $.marketForTranche[tranche];
        if (marketId == bytes32(0)) revert ILender.InvalidTranche();

        updateRewards($, marketId);
        reward = $.claimableTrancheReward(tranche, msg.sender);
        $.market[marketId].pendingReward[tranche][msg.sender] = 0;
        IStablecoin($.stablecoin).mintUnbacked(recipient, reward);
        emit ILender.ClaimTrancheReward(tranche, recipient, reward);
    }
}
