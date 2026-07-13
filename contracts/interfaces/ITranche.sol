// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ITranche
/// @author kexley, Cap Labs
/// @notice Interface for Tranche contract
interface ITranche is IERC7540AsyncRedeem {
    struct Storage {
        address market;
        address vault;
        address irm;
        address stablecoin;
        EnumerableSet.AddressSet whitelist;
        mapping(address => uint256) pendingReward;
        mapping(address => uint256) rewardDebt;
        uint256 rewardPerShare;
        uint256 lastRewardUpdate;
    }

    error Unauthorized();

    event Slashed(address indexed recipient, uint256 amount);
    event Claimed(address indexed user, address indexed recipient, uint256 amount);

    function initialize(address authority, address asset, string memory name, string memory symbol, address market)
        external;

    /// @notice Slash the tranche's assets
    /// @param assets The amount of assets to slash
    /// @param recipient The recipient of the slashed assets
    /// @return slashedAssets The amount of assets slashed
    function slash(uint256 assets, address recipient) external returns (uint256 slashedAssets);
    function updateIrm() external;
    function setWhitelist(address account, bool allowed) external;
    function whitelisted(address account) external view returns (bool allowed);
    function market() external view returns (address);
    function claim(address recipient) external returns (uint256 reward);
    function claimable(address user) external view returns (uint256 reward);
}
