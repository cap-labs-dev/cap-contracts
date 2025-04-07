// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

contract MockOracle {
    mapping(address => uint256) private prices; // 18 decimals
    mapping(address => uint256) private staleness; // seconds
    uint256 public constant PRICE_PRECISION = 1e18;

    event PriceUpdated(address asset, uint256 price);

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    function setPriceStaleness(address asset, uint256 _staleness) external {
        staleness[asset] = _staleness;
    }

    function getPrice(address asset) external view returns (uint256, uint256) {
        /// @dev lastUpdate is not used in the mock oracle
        return (prices[asset], block.timestamp - staleness[asset]);
    }
}
