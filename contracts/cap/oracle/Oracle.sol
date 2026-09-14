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
contract Oracle layout at erc7201("cap.storage.Oracle") is IOracle, AccessManagedUpgradeable, UUPSUpgradeable {
    /// @inheritdoc IOracle
    uint8 public constant DECIMALS = 18;

    /// @dev Identity for composing a chain
    uint256 private constant ONE = 10 ** DECIMALS;

    /// @dev Source chain. Private so the generated getter cannot return a single index or drop `payload`.
    mapping(address asset => Sources[] sources) private _chain;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IOracle
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    /// @inheritdoc IOracle
    function setSource(address _asset, Sources[] calldata _sources) external restricted {
        if (_sources.length != 0 && _price(_sources) == 0) revert PriceError(_asset);

        delete _chain[_asset];
        for (uint256 i; i < _sources.length; ++i) {
            _chain[_asset].push(_sources[i]);
        }
        emit SetSource(_asset, _sources);
    }

    /// @inheritdoc IOracle
    function price(address _asset) external view returns (uint256 latestAnswer) {
        latestAnswer = _price(_chain[_asset]);
    }

    /// @inheritdoc IOracle
    function price(Sources[] calldata _sources) external view returns (uint256 latestAnswer) {
        latestAnswer = _price(_sources);
    }

    /// @inheritdoc IOracle
    function sources(address _asset) external view returns (Sources[] memory sourceChain) {
        sourceChain = _chain[_asset];
    }

    /// @dev Product of each hop. Zero if the chain is empty or a hop cannot answer.
    function _price(Sources[] memory _sources) private view returns (uint256 answer) {
        uint256 length = _sources.length;
        if (length == 0) return 0;

        answer = _fetchPrice(_sources[0]);
        for (uint256 i = 1; i < length; ++i) {
            answer = Math.mulDiv(answer, _fetchPrice(_sources[i]), ONE);
        }
    }

    /// @dev Primary, then secondary. Zero if both are stale or otherwise unusable.
    function _fetchPrice(Sources memory _source) private view returns (uint256 latestAnswer) {
        latestAnswer = _read(_source.primary.adapter, _source.primary.payload, _source.primary.staleness);
        if (latestAnswer == 0) {
            latestAnswer = _read(_source.secondary.adapter, _source.secondary.payload, _source.secondary.staleness);
        }
    }

    /// @dev Staticcall the adapter; return zero if the answer is unusable
    function _read(address _adapter, bytes memory _payload, uint256 _staleness)
        private
        view
        returns (uint256 latestAnswer)
    {
        (bool success, bytes memory returnedData) = _adapter.staticcall(_payload);

        if (success && returnedData.length == 64) {
            uint256 lastUpdated;
            (latestAnswer, lastUpdated) = abi.decode(returnedData, (uint256, uint256));
            if (_isStale(block.timestamp, lastUpdated, _staleness)) return 0;
        }
    }

    /// @dev An answer stamped ahead of the block is not old
    function _isStale(uint256 _currentTimestamp, uint256 _lastUpdated, uint256 _staleness)
        internal
        pure
        returns (bool isStale)
    {
        if (_currentTimestamp > _lastUpdated) isStale = _currentTimestamp - _lastUpdated > _staleness;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
