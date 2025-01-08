// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRegistry} from "../../interfaces/IRegistry.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

/// @title Cap Token Adapter
/// @notice Prices are calculated based on the weighted average of underlying assets
contract CapTokenAdapter {
    IRegistry public immutable registry;

    constructor(address _registry) {
        registry = IRegistry(_registry);
    }

    /// @notice Fetch price for a cap token based on its underlying assets
    /// @param _asset Cap token address
    /// @return latestAnswer Price of the cap token fixed to 8 decimals
    function price(address, address _asset) external view returns (uint256 latestAnswer) {
        address vault = registry.basketVault(_asset);
        address[] memory assets = registry.basketAssets(_asset);
        address priceOracle = registry.priceOracle();

        uint256 totalUsdValue;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 supply = IVault(vault).totalSupplies(asset);
            uint8 supplyDecimals = IERC20Metadata(asset).decimals();
            uint256 assetPrice = IPriceOracle(priceOracle).getPrice(asset);

            totalUsdValue += supply * assetPrice / supplyDecimals;
        }

        uint256 capTokenSupply = IERC20Metadata(_asset).totalSupply();
        uint8 decimals = IERC20Metadata(_asset).decimals();
        latestAnswer = totalUsdValue * decimals / capTokenSupply;
    }
}
