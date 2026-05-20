// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../access/Access.sol";
import { ICapChainlinkPoRAddressList } from "../../interfaces/ICapChainlinkPoRAddressList.sol";

import { IFractionalReserve } from "../../interfaces/IFractionalReserve.sol";
import { IFractionalReserveVault } from "../../interfaces/IFractionalReserveVault.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { CapChainlinkPoRAddressListStorageUtils } from "../../storage/CapChainlinkPoRAddressListStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Chainlink PoR Address List
/// @author weso, Cap Labs
/// @dev This contract is used to store the list of addresses that are used to verify the proof of reserves for cUSD
contract CapChainlinkPoRAddressList is
    ICapChainlinkPoRAddressList,
    UUPSUpgradeable,
    Access,
    CapChainlinkPoRAddressListStorageUtils
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _accessControl The address of the access control contract
    /// @param _cusd The address of the cUSD vault
    function initialize(address _accessControl, address _cusd) public initializer {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        $.cusd = IVault(_cusd);
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function getPoRAddressListLength() external view returns (uint256) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        address[] memory addresses = $.cusd.assets();

        if (addresses.length == 0) {
            return 0;
        }

        // Count total entries (base entries + vault queue entries)
        uint256 totalEntries;
        for (uint256 i; i < addresses.length; ++i) {
            totalEntries++; // Base entry for each address

            address vault = IFractionalReserve(address($.cusd)).fractionalReserveVault(addresses[i]);
            if (vault != address(0)) {
                address[] memory queue = IFractionalReserveVault(vault).get_default_queue();
                totalEntries += queue.length;
            }
        }

        return totalEntries;
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function getPoRAddressList(uint256 startIndex, uint256 endIndex) external view returns (PoRInfo[] memory _infos) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        if (startIndex > endIndex) {
            return new PoRInfo[](0);
        }

        address[] memory addresses = _getcUSDAssets();
        if (addresses.length == 0) {
            return new PoRInfo[](0);
        }

        endIndex = endIndex > addresses.length - 1 ? addresses.length - 1 : endIndex;

        // First pass: count total entries needed
        uint256 totalEntries;
        for (uint256 i = startIndex; i <= endIndex; i++) {
            totalEntries++; // Base entry for each address

            address vault = IFractionalReserve(address($.cusd)).fractionalReserveVault(addresses[i]);
            if (vault != address(0)) {
                address[] memory queue = IFractionalReserveVault(vault).get_default_queue();
                totalEntries += queue.length;
            }
        }

        // Allocate array with correct size
        _infos = new PoRInfo[](totalEntries);
        uint256 infoIndex;

        // Second pass: populate the array
        for (uint256 currIdx = startIndex; currIdx <= endIndex; currIdx++) {
            // Add base entry for the current address
            _infos[infoIndex] = PoRInfo({
                chain: "ethereum",
                chainId: 1,
                tokenSymbol: IERC20Metadata(addresses[currIdx]).symbol(),
                tokenAddress: addresses[currIdx],
                tokenDecimals: IERC20Metadata(addresses[currIdx]).decimals(),
                tokenPriceOracle: $.tokenPriceOracles[addresses[currIdx]],
                yourVaultAddress: address($.cusd)
            });
            infoIndex++;

            // Add entries for vault queue if it exists
            address vault = IFractionalReserve(address($.cusd)).fractionalReserveVault(addresses[currIdx]);
            if (vault != address(0)) {
                address[] memory queue = IFractionalReserveVault(vault).get_default_queue();
                for (uint256 i; i < queue.length; ++i) {
                    _infos[infoIndex] = PoRInfo({
                        chain: "ethereum",
                        chainId: 1,
                        tokenSymbol: IERC20Metadata(addresses[currIdx]).symbol(),
                        tokenAddress: $.tokenYieldAssets[addresses[currIdx]] != address(0)
                            ? $.tokenYieldAssets[addresses[currIdx]]
                            : addresses[currIdx],
                        tokenDecimals: IERC20Metadata(addresses[currIdx]).decimals(),
                        tokenPriceOracle: $.tokenPriceOracles[addresses[currIdx]],
                        yourVaultAddress: queue[i]
                    });
                    infoIndex++;
                }
            }
        }

        return _infos;
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function addTokenPriceOracle(address _token, address _oracle)
        external
        checkAccess(this.addTokenPriceOracle.selector)
    {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        $.tokenPriceOracles[_token] = _oracle;
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function addTokenYieldAsset(address _token, address _yieldAsset)
        external
        checkAccess(this.addTokenYieldAsset.selector)
    {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        $.tokenYieldAssets[_token] = _yieldAsset;
    }

    /// @dev Get the list of assets supported by the vault
    /// @return assets List of assets
    function _getcUSDAssets() private view returns (address[] memory) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        return $.cusd.assets();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override checkAccess(bytes4(0)) { }
}
