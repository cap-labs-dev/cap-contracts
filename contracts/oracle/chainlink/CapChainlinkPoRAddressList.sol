// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../access/Access.sol";
import { ICapChainlinkPoRAddressList } from "../../interfaces/ICapChainlinkPoRAddressList.sol";
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
        return _getcUSDAssets().length;
    }

    /// @inheritdoc ICapChainlinkPoRAddressList
    function getPoRAddressList(uint256 startIndex, uint256 endIndex) external view returns (PoRInfo[] memory _infos) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        if (startIndex > endIndex) {
            return new PoRInfo[](0);
        }

        address[] memory addresses = _getcUSDAssets();
        endIndex = endIndex > addresses.length - 1 ? addresses.length - 1 : endIndex;
        _infos = new PoRInfo[](endIndex - startIndex + 1);
        uint256 currIdx = startIndex;
        uint256 strAddrIdx = 0;
        while (currIdx <= endIndex) {
            PoRInfo memory info = PoRInfo({
                chain: "ethereum",
                chainId: 1,
                tokenSymbol: IERC20Metadata(addresses[currIdx]).symbol(),
                tokenAddress: addresses[currIdx],
                tokenDecimals: IERC20Metadata(addresses[currIdx]).decimals(),
                tokenPriceOracle: $.tokenPriceOracles[addresses[currIdx]],
                yourVaultAddress: address($.cusd)
            });
            _infos[strAddrIdx] = info;
            strAddrIdx++;
            currIdx++;
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

    /// @dev Get the list of assets supported by the vault
    /// @return assets List of assets
    function _getcUSDAssets() private view returns (address[] memory) {
        CapChainlinkPoRAddressListStorage storage $ = getCapChainlinkPoRAddressListStorage();
        return $.cusd.assets();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override checkAccess(bytes4(0)) { }
}
