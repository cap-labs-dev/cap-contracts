// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IVault } from "./IVault.sol";

/// @title ICapChainlinkPoRAddressList
/// @author weso, Cap Labs
/// @notice Interface for the CapChainlinkPoRAddressList contract
interface ICapChainlinkPoRAddressList {
    struct CapChainlinkPoRAddressListStorage {
        IVault cusd;
    }
    /// @notice Get the length of the PoR address list
    /// @return length Length of the PoR address list

    function getPoRAddressListLength() external view returns (uint256 length);

    /// @notice Get the PoR address list
    /// @param startIndex Start index
    /// @param endIndex End index
    /// @return addresses List of addresses
    function getPoRAddressList(uint256 startIndex, uint256 endIndex)
        external
        view
        returns (string[] memory addresses);
}
