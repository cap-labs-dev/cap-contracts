// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IRewarder } from "../interfaces/IRewarder.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { RewarderStorageUtils } from "../storage/RewarderStorageUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Rewarder
/// @author kexley
/// @notice The Rewarder is the central contract for the Cap protocol. It is responsible for managing the markets and the underwriters.
contract Rewarder is IRewarder, AccessManagedUpgradeable, RewarderStorageUtils, UUPSUpgradeable {
    using WadRayMath for uint256;

    /// @notice Initialize the Rewarder
    /// @param _authority The authority address
    /// @param _lender The address of the lender
    /// @param _stablecoin The address of the stablecoin
    /// @param _irm The address of the interest rate model
    function initialize(address _authority, address _lender, address _stablecoin, address _irm) external initializer {
        __AccessManaged_init(_authority);
        Storage storage $ = getRewarderStorage();
        $.lender = _lender;
        $.stablecoin = _stablecoin;
        $.irm = _irm;
    }

    /// @notice Register a market's underwriter tranches
    /// @dev Callable only by the Lender when a market is created
    /// @param marketId The market to register
    /// @param seniorUnderwriter The senior underwriter tranche
    /// @param juniorUnderwriter The junior underwriter tranche
    function registerMarket(bytes32 marketId, address seniorUnderwriter, address juniorUnderwriter) external {
        Storage storage $ = getRewarderStorage();
        if (msg.sender != $.lender) revert Unauthorized();
        Market storage market = $.market[marketId];
        market.seniorUnderwriter = seniorUnderwriter;
        market.juniorUnderwriter = juniorUnderwriter;
        emit RegisterMarket(marketId, seniorUnderwriter, juniorUnderwriter);
    }

    /// @notice Set the staked cUSD recipient of supply rewards
    /// @param _stcUSD The new staked cUSD address
    function setStcUSD(address _stcUSD) external restricted {
        getRewarderStorage().stcUSD = _stcUSD;
        emit SetStcUSD(_stcUSD);
    }

    /// @notice Set the junior split for a market
    /// @param marketId The market to set the junior split for
    /// @param juniorSplit The new junior split
    function setJuniorSplit(bytes32 marketId, uint256 juniorSplit) external {
        Market storage market = getRewarderStorage().market[marketId];
        if (msg.sender != market.seniorUnderwriter && msg.sender != market.juniorUnderwriter) revert Unauthorized();
        if (juniorSplit > 1e27) revert InvalidJuniorSplit();
        market.juniorSplit = juniorSplit;
        emit SetJuniorSplit(marketId, juniorSplit);
    }

    /// @notice Accrue rewards for a market
    /// @param marketId The market to update
    function updateRewards(bytes32 marketId) public {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        if (market.lastIndexUpdate == block.timestamp) return;

        uint256 supplyIndex = ILender($.lender).supplyIndex(marketId);
        uint256 underwriterIndex = ILender($.lender).underwriterIndex(marketId);
        uint256 scaledDebt = ILender($.lender).scaledDebt(marketId);

        if (scaledDebt > 0) {
            uint256 supplyInterest =
                scaledDebt.rayMul(market.lastUnderwriterIndex.rayMul(supplyIndex - market.lastSupplyIndex));
            uint256 premiumInterest =
                scaledDebt.rayMul(supplyIndex.rayMul(underwriterIndex - market.lastUnderwriterIndex));

            if (supplyInterest > 0) $.supplyReward += supplyInterest;

            uint256 juniorInterest = premiumInterest.rayMul(market.juniorSplit);
            uint256 seniorInterest = premiumInterest - juniorInterest;

            uint256 seniorSupply = IUnderwriter(market.seniorUnderwriter).activeSupply();
            uint256 juniorSupply = IUnderwriter(market.juniorUnderwriter).activeSupply();

            if (seniorInterest > 0) {
                if (seniorSupply > 0) {
                    market.rewardPerShare[market.seniorUnderwriter] += seniorInterest.rayDiv(seniorSupply);
                } else if (juniorSupply > 0) {
                    market.rewardPerShare[market.juniorUnderwriter] += seniorInterest.rayDiv(juniorSupply);
                } else {
                    $.supplyReward += seniorInterest;
                }
            }

            if (juniorInterest > 0) {
                if (juniorSupply > 0) {
                    market.rewardPerShare[market.juniorUnderwriter] += juniorInterest.rayDiv(juniorSupply);
                } else if (seniorSupply > 0) {
                    market.rewardPerShare[market.seniorUnderwriter] += juniorInterest.rayDiv(seniorSupply);
                } else {
                    $.supplyReward += juniorInterest;
                }
            }
        }

        market.lastSupplyIndex = supplyIndex;
        market.lastUnderwriterIndex = underwriterIndex;
        market.lastIndexUpdate = block.timestamp;
    }

    /// @notice Update the supply index for a market
    /// @param marketId The market to update
    function updateSupplyIndex(bytes32 marketId) external {
        Storage storage $ = getRewarderStorage();
        if (msg.sender != $.lender) revert Unauthorized();
        Market storage market = $.market[marketId];
        market.lastSupplyIndex = ILender($.lender).supplyIndex(marketId);
    }

    /// @notice Increase reward debt for a user
    /// @param marketId The market to update
    /// @param user The user to increase reward debt for
    /// @param amount The amount of reward debt to increase
    function increaseRewardDebt(bytes32 marketId, address user, uint256 amount) external {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        if (msg.sender != market.juniorUnderwriter && msg.sender != market.seniorUnderwriter) {
            revert Unauthorized();
        }

        updateRewards(marketId);
        IInterestRateModel($.irm).update(marketId);
        uint256 accRewardPerShare = rewardPerShare(marketId, msg.sender);
        uint256 balance = IERC20(msg.sender).balanceOf(user);
        market.pendingReward[msg.sender][user] += accRewardPerShare.rayMul(balance)
        - market.rewardDebt[msg.sender][user];
        // checkpoint the user's reward debt against their post-change balance (MasterChef-style)
        market.rewardDebt[msg.sender][user] = accRewardPerShare.rayMul(balance + amount);
    }

    /// @notice Decrease reward debt for a user
    /// @param marketId The market to update
    /// @param user The user to decrease reward debt for
    /// @param amount The amount of reward debt to decrease
    function decreaseRewardDebt(bytes32 marketId, address user, uint256 amount) external {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        if (msg.sender != market.juniorUnderwriter && msg.sender != market.seniorUnderwriter) {
            revert Unauthorized();
        }

        updateRewards(marketId);
        IInterestRateModel($.irm).update(marketId);
        uint256 accRewardPerShare = rewardPerShare(marketId, msg.sender);
        uint256 balance = IERC20(msg.sender).balanceOf(user);
        market.pendingReward[msg.sender][user] += accRewardPerShare.rayMul(balance)
        - market.rewardDebt[msg.sender][user];
        // checkpoint the user's reward debt against their post-change balance (MasterChef-style)
        market.rewardDebt[msg.sender][user] = accRewardPerShare.rayMul(balance - amount);
    }

    /// @notice Claim accumulated supply interest as stcUSD
    /// @return reward The amount minted to stcUSD
    function claimSupplyReward() external returns (uint256 reward) {
        Storage storage $ = getRewarderStorage();
        reward = $.supplyReward;
        $.supplyReward = 0;
        IStablecoin($.stablecoin).mintUnbacked($.stcUSD, reward);
        emit ClaimSupplyReward(reward);
    }

    /// @notice Mint underwriter premium rewards to a recipient
    /// @param marketId The market to query
    /// @param underwriter The underwriter to query
    /// @param recipient The recipient of the reward
    /// @return reward The amount of reward claimed
    function claimUnderwriterReward(bytes32 marketId, address underwriter, address recipient)
        external
        returns (uint256 reward)
    {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        if (underwriter != market.juniorUnderwriter && underwriter != market.seniorUnderwriter) {
            revert Unauthorized();
        }

        updateRewards(marketId);
        reward = claimableUnderwriterReward(marketId, underwriter, msg.sender);
        market.pendingReward[underwriter][msg.sender] = 0;
        IStablecoin($.stablecoin).mintUnbacked(recipient, reward);
        emit ClaimUnderwriterReward(marketId, underwriter, recipient, reward);
    }

    /// @notice Get the claimable supply reward
    /// @return reward The claimable supply reward
    function claimableSupplyReward() external view returns (uint256 reward) {
        reward = getRewarderStorage().supplyReward;
    }

    /// @notice Get the claimable underwriter reward
    /// @param marketId The market to query
    /// @param underwriter The underwriter to query
    /// @param user The user to query
    /// @return reward The claimable underwriter reward
    function claimableUnderwriterReward(bytes32 marketId, address underwriter, address user)
        public
        view
        returns (uint256 reward)
    {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        reward = market.pendingReward[underwriter][user]
            + rewardPerShare(marketId, underwriter).rayMul(IERC20(underwriter).balanceOf(user))
            - market.rewardDebt[underwriter][user];
    }

    /// @notice Get the accumulated reward per share for an underwriter tranche
    /// @dev Includes premium accrued since the last _update checkpoint. Mirrors the premium leg of
    /// _update and applies the same empty-tranche fallback.
    /// @param marketId The market to query
    /// @param underwriter The underwriter tranche to query
    /// @return accRewardPerShare The reward per share in ray
    function rewardPerShare(bytes32 marketId, address underwriter) public view returns (uint256 accRewardPerShare) {
        Storage storage $ = getRewarderStorage();
        Market storage market = $.market[marketId];
        accRewardPerShare = market.rewardPerShare[underwriter];

        uint256 supplyIndex = ILender($.lender).supplyIndex(marketId);
        uint256 underwriterIndex = ILender($.lender).underwriterIndex(marketId);
        uint256 scaledDebt = ILender($.lender).scaledDebt(marketId);
        uint256 supply = IUnderwriter(underwriter).activeSupply();

        if (scaledDebt > 0 && supply > 0 && market.lastIndexUpdate != block.timestamp) {
            uint256 premiumInterest =
                scaledDebt.rayMul(supplyIndex.rayMul(underwriterIndex - market.lastUnderwriterIndex));

            bool isJunior = underwriter == market.juniorUnderwriter;
            address other = isJunior ? market.seniorUnderwriter : market.juniorUnderwriter;
            uint256 share = IUnderwriter(other).activeSupply() == 0
                ? 1e27
                : (isJunior ? market.juniorSplit : 1e27 - market.juniorSplit);

            uint256 trancheInterest = premiumInterest.rayMul(share);
            if (trancheInterest > 0) accRewardPerShare += trancheInterest.rayDiv(supply);
        }
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
