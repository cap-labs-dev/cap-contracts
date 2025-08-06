// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapChainlinkPoRAddressList } from "../../interfaces/ICapChainlinkPoRAddressList.sol";

import { IVault } from "../../interfaces/IVault.sol";
import { CapChainlinkPoRAddressListStorageUtils } from "../../storage/CapChainlinkPoRAddressListStorageUtils.sol";

/// @title Chainlink PoR Address List
/// @author weso, Cap Labs
/// @dev This contract is used to store the list of addresses that are used to verify the proof of reserves for cUSD
contract CapChainlinkPoRAddressList is ICapChainlinkPoRAddressList, CapChainlinkPoRAddressListStorageUtils {
    /// @param _cusd The address of the cUSD vault
    constructor(address _cusd) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        $.cusd = IVault(_cusd);
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function getPoRAddressListLength() external view returns (uint256) {
        return _getcUSDAssets().length;
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function getPoRAddressList(uint256 startIndex, uint256 endIndex) external view returns (string[] memory) {
        if (startIndex > endIndex) {
            return new string[](0);
        }

        address[] memory addresses = _getcUSDAssets();
        endIndex = endIndex > addresses.length - 1 ? addresses.length - 1 : endIndex;
        string[] memory stringAddresses = new string[](endIndex - startIndex + 1);
        uint256 currIdx = startIndex;
        uint256 strAddrIdx = 0;
        while (currIdx <= endIndex) {
            stringAddresses[strAddrIdx] = _toString(abi.encodePacked(addresses[currIdx]));
            strAddrIdx++;
            currIdx++;
        }
        return stringAddresses;
    }

    /// @dev Get the list of assets supported by the vault
    /// @return assets List of assets
    function _getcUSDAssets() private view returns (address[] memory) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        return $.cusd.assets();
    }

    /// @dev Convert bytes to string
    /// @param data Bytes to convert
    /// @return String representation of bytes
    function _toString(bytes memory data) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }
}
