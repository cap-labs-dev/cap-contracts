// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IGatedERC1155ValidationHook
/// @author kexley, Cap Labs
/// @notice Interface for Gated ERC1155 Validation Hook
interface IGatedERC1155ValidationHook is IERC165 {
    /// @notice The block number until which the validation check is enforced
    function expirationBlock() external view returns (uint256);
    /// @notice The ERC1155 token contract that is checked for ownership
    /// @dev Callers should query the returned interface's `balanceOf` method
    function erc1155() external view returns (IERC1155);
    /// @notice The ERC1155 tokenId that is checked for ownership
    function tokenId() external view returns (uint256);
    /// @notice Validate a bid
    /// @dev MUST revert if the bid is invalid
    /// @param _maxPrice The maximum price the bidder is willing to pay
    /// @param _amount The amount of the bid
    /// @param _owner The owner of the bid
    /// @param _sender The sender of the bid
    /// @param _hookData Additional data to pass to the hook required for validation
    function validate(uint256 _maxPrice, uint128 _amount, address _owner, address _sender, bytes calldata _hookData)
        external;
}
