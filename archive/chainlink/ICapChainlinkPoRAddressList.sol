// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IVault } from "./IVault.sol";

/// @title ICapChainlinkPoRAddressList
/// @author weso, Cap Labs
/// @notice Interface for the CapChainlinkPoRAddressList contract
interface ICapChainlinkPoRAddressList {
    struct CapChainlinkPoRAddressListStorage {
        IVault cusd;
        mapping(address => address) tokenPriceOracles;
        mapping(address => address) tokenYieldAssets;
    }

    struct PoRInfo {
        string chain;
        uint256 chainId;
        string tokenSymbol;
        address tokenAddress;
        uint8 tokenDecimals;
        address tokenPriceOracle; //optional
        address yourVaultAddress;
    }

    /// @notice Get the length of the PoR address list
    /// @return length Length of the PoR address list
    function getPoRAddressListLength() external view returns (uint256 length);

    /// @notice Get the PoR address list
    /// @param startIndex Start index
    /// @param endIndex End index
    /// @return info PoRInfo array
    function getPoRAddressList(uint256 startIndex, uint256 endIndex) external view returns (PoRInfo[] memory info);

    /// @notice Add a token price oracle
    /// @param _token Token address
    /// @param _oracle Oracle address
    function addTokenPriceOracle(address _token, address _oracle) external;

    /// @notice Add a token yield asset
    /// @param _token Token address
    /// @param _yieldAsset Yield asset address
    function addTokenYieldAsset(address _token, address _yieldAsset) external;
}
