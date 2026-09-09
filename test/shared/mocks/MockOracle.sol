// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IOracle } from "../../../contracts/interfaces/IOracle.sol";

/// @notice Minimal oracle mock returning configurable prices for tests.
///
/// Answers from a stored price rather than by pricing a chain through adapters, because almost
/// nothing in the suite cares how a price was assembled and every test that did would need an
/// adapter and a payload to say so. {Oracle} itself is covered directly in its own unit tests,
/// chains included.
///
/// Refuses a missing or stale price rather than handing one back, which is the part of {Oracle}
/// its consumers actually lean on. A mock that answered regardless would be more permissive than
/// the contract it stands in for, and that is the direction that hides bugs.
contract MockOracle is IOracle {
    uint8 public constant DECIMALS = 8;

    mapping(address asset => uint256 price) private _price;
    mapping(address asset => uint256 timestamp) private _lastUpdated;
    mapping(address asset => uint256 window) private _staleness;
    mapping(address asset => bool set) private _stalenessSet;
    mapping(address asset => OracleData data) private _source;
    mapping(address asset => OracleData data) private _backup;
    mapping(address asset => address[] assets) private _chain;

    function initialize(address) external { }

    function setPrice(address asset, uint256 value) external {
        _price[asset] = value;
        _lastUpdated[asset] = block.timestamp;
    }

    /// @dev Lets a test freeze a feed without touching the price, so staleness can be exercised
    /// independently of a price move.
    function setLastUpdated(address asset, uint256 timestamp) external {
        _lastUpdated[asset] = timestamp;
    }

    function setStaleness(address asset, uint256 window) external {
        _staleness[asset] = window;
        _stalenessSet[asset] = true;
    }

    function setSource(address asset, OracleData calldata data) external {
        _source[asset] = data;
        emit SetSource(asset, data);
    }

    function setBackup(address asset, OracleData calldata data) external {
        _backup[asset] = data;
        emit SetBackup(asset, data);
    }

    function setChain(address asset, address[] calldata assets) external {
        _chain[asset] = assets;
        emit SetChain(asset, assets);
    }

    function price(address asset) external view returns (uint256 value, uint256 lastUpdated) {
        value = _price[asset];
        lastUpdated = _lastUpdated[asset];
        bool stale = block.timestamp > lastUpdated && block.timestamp - lastUpdated > _window(asset);
        if (value == 0 || stale) revert PriceError(asset);
    }

    function source(address asset) external view returns (OracleData memory data) {
        data = _source[asset];
    }

    function backup(address asset) external view returns (OracleData memory data) {
        data = _backup[asset];
    }

    function chain(address asset) external view returns (address[] memory assets) {
        assets = _chain[asset];
    }

    /// @dev A window never set reads as effectively unlimited rather than as zero. Zero is a real
    /// window and rejects anything not written in the same block, and the suite warps freely for
    /// vesting and interest without re-posting prices. Set explicitly the value stands as given,
    /// so a test can still ask for zero and exercise that edge.
    function _window(address asset) private view returns (uint256 window) {
        window = _stalenessSet[asset] ? _staleness[asset] : type(uint256).max;
    }
}
