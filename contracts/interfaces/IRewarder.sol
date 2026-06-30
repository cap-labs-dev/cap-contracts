// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IRewarder
/// @author kexley, Cap Labs
/// @notice Interface for Hub reward accrual and claims
interface IRewarder {
    struct Storage {
        address lender;
        address irm;
        mapping(bytes32 => Market) market;
        uint256 supplyReward;
        address stcUSD;
        address stablecoin;
    }

    struct Market {
        address seniorUnderwriter;
        address juniorUnderwriter;
        uint256 lastSupplyIndex;
        uint256 lastUnderwriterIndex;
        uint256 lastIndexUpdate;
        uint256 juniorSplit;
        mapping(address => uint256) rewardPerShare;
        mapping(address => mapping(address => uint256)) pendingReward;
        mapping(address => mapping(address => uint256)) rewardDebt;
    }

    error Unauthorized();
    error InvalidJuniorSplit();

    event SetJuniorSplit(bytes32 marketId, uint256 juniorSplit);
    event ClaimSupplyReward(uint256 reward);
    event ClaimUnderwriterReward(bytes32 marketId, address underwriter, address recipient, uint256 reward);

    function setJuniorSplit(bytes32 marketId, uint256 juniorSplit) external;
    function updateRewards(bytes32 marketId) external;
    function updateSupplyIndex(bytes32 marketId) external;
    function increaseRewardDebt(bytes32 marketId, address user, uint256 amount) external;
    function decreaseRewardDebt(bytes32 marketId, address user, uint256 amount) external;
    function claimSupplyReward() external returns (uint256 reward);
    function claimUnderwriterReward(bytes32 marketId, address underwriter, address recipient)
        external
        returns (uint256 reward);
    function claimableSupplyReward() external view returns (uint256 reward);
    function claimableUnderwriterReward(bytes32 marketId, address underwriter, address caller)
        external
        view
        returns (uint256 reward);
}
