// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRegistry {
    struct Basket {
        string name;
        address vault;
        address[] assets;
        uint256 baseFee;
    }

    struct BasketFees {
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    function basketVault(address cToken) external view returns (address vault);
    function basketAssets(address cToken) external view returns (address[] memory assets);
    function basketBaseFee(address cToken) external view returns (uint256 baseFee);
    function basketFees(address cToken, address asset) external view returns (BasketFees memory basketFees);
    function basketRedeemFee(address cToken) external view returns (uint256 fee);
    function supportedCToken(address cToken) external view returns (bool supported);
    function basketSupportsAsset(address cToken, address asset) external view returns (bool supported);
    function vaultSupportsAsset(address vault, address asset) external view returns (bool supported);

    function oracle() external view returns (address oracle);
    function collateral() external view returns (address collateral);
    function debtTokenInstance() external view returns (address debtTokenInstance);
    function minter() external view returns (address minter);
    function restakerRewarder(address agent) external view returns (address restakerRewarder);
    function rewarder(address asset) external view returns (address rewarder);
    function assetManager() external view returns (address manager);
}
