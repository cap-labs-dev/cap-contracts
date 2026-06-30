// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IUnderwriter
/// @author kexley, Cap Labs
/// @notice Interface for Underwriter contract
interface IUnderwriter is IERC7540AsyncRedeem {
    error UnauthorizedRedemption();
    error Unauthorized();

    struct Storage {
        address lender;
        address vault;
        address rewarder;
        address irm;
        bytes32 marketId;
        EnumerableSet.AddressSet whitelist;
    }

    function initialize(
        bytes32 marketId,
        string memory name,
        string memory symbol,
        address asset,
        address manager,
        address vault,
        address rewarder,
        address irm
    ) external;
    function slash(uint256 assets, address recipient) external returns (uint256 slashedAssets);
}
