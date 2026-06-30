// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";

/// @title IERC1155Queue
/// @notice IERC1155Queue is the interface for the ERC1155 queue NFTs
interface IERC1155Queue is IERC1155 {
    /// @notice Mint a redemption NFT to an address
    /// @param _to The address to mint the redemption NFT to
    /// @param _id The id of the redemption NFT
    /// @param _amount The amount of redemption NFTs to mint
    function mint(address _to, uint256 _id, uint256 _amount) external;

    /// @notice Burn a redemption NFT from an address
    /// @param _from The address to burn the redemption NFT from
    /// @param _id The id of the redemption NFT
    /// @param _amount The amount of redemption NFTs to burn
    function burn(address _from, uint256 _id, uint256 _amount) external;
}
