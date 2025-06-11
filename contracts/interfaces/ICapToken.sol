// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IFractionalReserve } from "./IFractionalReserve.sol";
import { IMinter } from "./IMinter.sol";
import { IVault } from "./IVault.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title Cap Token interface
/// @author @capLabs
/// @notice Interface for the Cap Token contract
interface ICapToken is IERC20, IVault, IMinter, IFractionalReserve {
    /// @notice Initialize the Cap token
    /// @param name Name of the cap token
    /// @param symbol Symbol of the cap token
    /// @param accessControl Access controller
    /// @param feeAuction Fee auction address
    /// @param oracle Oracle address
    /// @param assets Asset addresses to mint Cap token with
    /// @param insuranceFund Insurance fund
    function initialize(
        string memory name,
        string memory symbol,
        address accessControl,
        address feeAuction,
        address oracle,
        address[] calldata assets,
        address insuranceFund
    ) external;
}
