// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IOracle } from "../../interfaces/IOracle.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Oracle
/// @author kexley, Cap Labs
/// @notice Oracle for fetching prices from external sources
contract Oracle layout at erc7201("cap.storage.Oracle") is IOracle, UUPSUpgradeable, AccessManagedUpgradeable {
    /// @inheritdoc IOracle
    uint8 public constant DECIMALS = 8;

    /// @dev One in {DECIMALS} fixed point, which is the identity a chain composes from
    uint256 private constant ONE = 10 ** DECIMALS;

    /// @dev Read through {source}, {backup} and {chain} rather than made public. The getter
    /// Solidity generates for a mapping to a struct returns the members one by one and drops the
    /// dynamic ones, so it would hand back an entry without its payload, and the one for a mapping
    /// to an array takes an index rather than returning the chain. Neither satisfies the interface
    mapping(address asset => OracleData data) private _source;

    mapping(address asset => OracleData data) private _backup;

    mapping(address asset => address[] assets) private _chain;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IOracle
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    /// @inheritdoc IOracle
    function setSource(address _asset, OracleData calldata _data) external restricted {
        _checkWindow(_asset, _data);
        _source[_asset] = _data;
        emit SetSource(_asset, _data);
    }

    /// @inheritdoc IOracle
    function setBackup(address _asset, OracleData calldata _data) external restricted {
        _checkWindow(_asset, _data);
        _backup[_asset] = _data;
        emit SetBackup(_asset, _data);
    }

    /// @inheritdoc IOracle
    function setChain(address _asset, address[] calldata _assets) external restricted {
        uint256 length = _assets.length;
        for (uint256 i; i < length; ++i) {
            // an asset of zero has no entries and never will, so it would compose in as a zero and
            // take the whole chain with it on every read
            if (_assets[i] == address(0)) revert InvalidChainAsset(_asset, i);
        }

        _chain[_asset] = _assets;
        emit SetChain(_asset, _assets);
    }

    /// @inheritdoc IOracle
    function price(address _asset) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        address[] storage legs = _chain[_asset];
        uint256 length = legs.length;

        if (length == 0) {
            (latestAnswer, lastUpdated) = _priceOne(_asset);
            if (latestAnswer == 0) revert PriceError(_asset);
            return (latestAnswer, lastUpdated);
        }

        latestAnswer = ONE;
        lastUpdated = type(uint256).max;

        for (uint256 i; i < length; ++i) {
            address leg = legs[i];
            (uint256 answer, uint256 legUpdated) = _priceOne(leg);
            // named for the leg rather than the asset asked for, because the leg is the thing
            // whose feed needs attention and the chain is a configuration detail from out here
            if (answer == 0) revert PriceError(leg);

            // {Math-mulDiv} rather than a plain product, which would overflow on a pair of large
            // answers that the division afterwards brings back into range anyway
            latestAnswer = Math.mulDiv(latestAnswer, answer, ONE);
            // a chain is only as fresh as its stalest link, so that is the stamp callers measure
            // against even though each leg has already been checked against its own window
            if (legUpdated < lastUpdated) lastUpdated = legUpdated;
        }

        // legs that are individually fine can still truncate to nothing between them, and zero is
        // what no price means everywhere else in here
        if (latestAnswer == 0) revert PriceError(_asset);
    }

    /// @inheritdoc IOracle
    function source(address _asset) external view returns (OracleData memory data) {
        data = _source[_asset];
    }

    /// @inheritdoc IOracle
    function backup(address _asset) external view returns (OracleData memory data) {
        data = _backup[_asset];
    }

    /// @inheritdoc IOracle
    function chain(address _asset) external view returns (address[] memory assets) {
        assets = _chain[_asset];
    }

    /// @dev Price one asset from its source, falling back to its backup.
    ///
    /// Reads the asset's own entries and never its chain, so an asset may appear in its own chain
    /// without recursion. That is the natural shape for a derived price: the source holds the
    /// ratio, and the chain is the asset itself followed by whatever it is a ratio of.
    ///
    /// Answers zero for no price rather than reverting, so a failing source can be retried against
    /// the backup. A real answer is never zero, since adapters refuse a non-positive reading
    /// instead of passing it on, so the sentinel cannot collide with a price anyone would act on.
    /// @param _asset Asset to price
    /// @return latestAnswer Price, or zero if neither entry could answer
    /// @return lastUpdated When the answering entry was written
    function _priceOne(address _asset) private view returns (uint256 latestAnswer, uint256 lastUpdated) {
        OracleData storage data = _source[_asset];
        (latestAnswer, lastUpdated) = _read(data.adapter, data.payload, data.staleness);

        if (latestAnswer == 0) {
            data = _backup[_asset];
            (latestAnswer, lastUpdated) = _read(data.adapter, data.payload, data.staleness);
        }
    }

    /// @dev Call an adapter and take its answer only if it is usable, without reverting on anything
    /// the adapter does
    /// @param _adapter Adapter for calculation logic
    /// @param _payload Encoded call to adapter with all required data
    /// @param _staleness How old the answer may be
    /// @return latestAnswer Calculated price, or zero if unusable
    /// @return lastUpdated Last updated timestamp
    function _read(address _adapter, bytes memory _payload, uint256 _staleness)
        private
        view
        returns (uint256 latestAnswer, uint256 lastUpdated)
    {
        (bool success, bytes memory returnedData) = _adapter.staticcall(_payload);

        // Length-checked before decoding, because a staticcall to an account with no code succeeds
        // and returns nothing. An asset with no entry names an adapter of zero and takes exactly
        // that path, so decoding straight through would revert here rather than report no price,
        // and would take the backup down with it on the way past. It also catches a rate-style
        // adapter that answers a value with no timestamp, which is one word rather than two
        if (success && returnedData.length >= 64) {
            (latestAnswer, lastUpdated) = abi.decode(returnedData, (uint256, uint256));
            if (_isStale(block.timestamp, lastUpdated, _staleness)) return (0, 0);
        }
    }

    /// @dev Reject an entry that names an adapter but no window, where nobody is looking yet.
    ///
    /// A window of zero admits only an answer written in the calling block, so it cannot be told
    /// apart from never having been configured, and it leaves an asset that reverts on all but a
    /// handful of reads. The read it reverts on is inside a health check or a redemption rather
    /// than here. An entry with no adapter is a deliberate clearing and carries no window to check
    /// @param _asset Asset being configured
    /// @param _data The entry being set
    function _checkWindow(address _asset, OracleData calldata _data) private pure {
        if (_data.adapter != address(0) && _data.staleness == 0) revert NoStaleness(_asset);
    }

    /// @dev Check if a price is stale
    /// @param _currentTimestamp Current timestamp
    /// @param _lastUpdated Last updated timestamp
    /// @param _staleness Staleness period
    /// @return isStale True if the price is stale
    function _isStale(uint256 _currentTimestamp, uint256 _lastUpdated, uint256 _staleness)
        internal
        pure
        returns (bool isStale)
    {
        // An answer stamped ahead of the block is not old, and subtracting straight through would
        // panic on it rather than fall to the backup. That turns one adapter reporting a bad
        // timestamp into a market that cannot price its collateral at all
        if (_currentTimestamp > _lastUpdated) {
            isStale = _currentTimestamp - _lastUpdated > _staleness;
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
