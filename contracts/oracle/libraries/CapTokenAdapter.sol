// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAddressProvider} from "../../interfaces/IAddressProvider.sol";
import {IVaultDataProvider} from "../../interfaces/IVaultDataProvider.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

/// @title Cap Token Adapter
/// @notice Prices are calculated based on the weighted average of underlying assets
library CapTokenAdapter {
    /// @notice Fetch price for a cap token based on its underlying assets
    /// @param _addressProvider Address provider
    /// @param _asset Cap token address
    /// @return latestAnswer Price of the cap token fixed to 8 decimals
    function price(address _addressProvider, address _asset) external view returns (uint256 latestAnswer) {
        uint256 capTokenSupply = IERC20Metadata(_asset).totalSupply();
        if (capTokenSupply == 0) return 1; // price of 0 triggers the backup adapter

        IVaultDataProvider vaultDataProvider =
            IVaultDataProvider(IAddressProvider(_addressProvider).vaultDataProvider());
        address vault = vaultDataProvider.vault(_asset);
        address[] memory assets = vaultDataProvider.vaultData(vault).assets;
        address priceOracle = IAddressProvider(_addressProvider).priceOracle();

        uint256 totalUsdValue;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 supply = IVault(vault).totalSupplies(asset);
            uint8 supplyDecimals = IERC20Metadata(asset).decimals();
            uint256 assetPrice = IPriceOracle(priceOracle).getPrice(asset);

            totalUsdValue += supply * assetPrice / supplyDecimals;
        }

        uint8 decimals = IERC20Metadata(_asset).decimals();
        latestAnswer = totalUsdValue * decimals / capTokenSupply;
    }
}
