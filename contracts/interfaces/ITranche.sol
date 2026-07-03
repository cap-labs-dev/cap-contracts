// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC7540AsyncRedeem } from "./IERC7540AsyncRedeem.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ITranche
/// @author kexley, Cap Labs
/// @notice Interface for Tranche contract
interface ITranche is IERC7540AsyncRedeem {
    error Unauthorized();

    struct Storage {
        bytes32 marketId;
        address vault;
        address irm;
        address lender;
        EnumerableSet.AddressSet whitelist;
    }

    /// @notice Initialize the tranche
    function initialize(
        address authority,
        bytes32 marketId,
        string memory name,
        string memory symbol,
        address asset,
        address vault,
        address irm
    ) external;

    /// @notice Slash the tranche's assets
    /// @param assets The amount of assets to slash
    /// @param recipient The recipient of the slashed assets
    /// @return slashedAssets The amount of assets slashed
    function slash(uint256 assets, address recipient) external returns (uint256 slashedAssets);

    /// @notice Update the interest rate model for the tranche
    function updateIRM() external;

    /// @notice Set the whitelist for a depositor into the tranche
    function setWhitelist(address account, bool allowed) external;

    /// @notice Check if an account is whitelisted
    function whitelisted(address account) external view returns (bool allowed);
}
