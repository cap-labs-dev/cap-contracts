// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";

/// @title IERC1155Queue
/// @author kexley, Cap Labs
/// @notice Interface for ERC-1155 queue NFTs used in async redemption
interface IERC1155Queue is IERC1155 {
    /// @notice Mint a redemption NFT to an address
    /// @param to The address to mint the redemption NFT to
    /// @param id The id of the redemption NFT
    /// @param amount The amount of redemption NFTs to mint
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice Burn a redemption NFT from an address
    /// @param from The address to burn the redemption NFT from
    /// @param id The id of the redemption NFT
    /// @param amount The amount of redemption NFTs to burn
    function burn(address from, uint256 id, uint256 amount) external;
}
