// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOracle } from "../../../contracts/interfaces/IOracle.sol";

/// @notice Minimal oracle mock returning configurable prices for tests
contract MockOracle is IOracle {
    mapping(address => uint256) private _price;
    mapping(address => uint256) private _lastUpdated;

    function setPrice(address asset, uint256 price) external {
        _price[asset] = price;
        _lastUpdated[asset] = block.timestamp;
    }

    function getPrice(address asset) external view returns (uint256 price, uint256 lastUpdated) {
        price = _price[asset];
        lastUpdated = _lastUpdated[asset];
    }

    function setPriceOracleData(address, OracleData calldata) external pure { }
    function setPriceBackupOracleData(address, OracleData calldata) external pure { }
    function setStaleness(address, uint256) external pure { }

    function priceOracleData(address) external pure returns (OracleData memory data) {
        return data;
    }

    function priceBackupOracleData(address) external pure returns (OracleData memory data) {
        return data;
    }

    function staleness(address) external pure returns (uint256) {
        return 0;
    }
}
