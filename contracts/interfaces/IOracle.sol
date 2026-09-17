// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IOracle
/// @author kexley, Cap Labs
/// @notice Interface for the unified price and rate oracle
/// @dev A chain of hops, each with a primary and optional secondary feed. Prices are in 18 decimals.
/// Stale or unusable reads are zero; the caller decides whether that is an error.
interface IOracle {
    /// @notice Get the fixed-point scale every adapter answers in (18, matching cUSD)
    /// @return decimals The answer decimals
    function DECIMALS() external view returns (uint8 decimals);

    /// @notice Primary and secondary source data for one hop
    /// @param primary The primary source
    /// @param secondary The secondary source, used when the primary cannot answer
    struct Sources {
        Source primary;
        Source secondary;
    }

    /// @notice Specific data for a source
    /// @param adapter The adapter returning exactly `(uint256 price, uint256 lastUpdated)`, with price in 18 decimals
    /// @param payload The encoded call to the adapter
    /// @param staleness The maximum age of the answer, in seconds
    struct Source {
        address adapter;
        bytes payload;
        uint256 staleness;
    }

    /// @notice Emitted when the source chain for an asset is updated
    /// @param asset The asset the chain prices
    /// @param sources The hops to multiply
    event SetSource(address indexed asset, Sources[] sources);

    /// @notice The asset has no usable price
    /// @param asset The asset that could not be priced
    error PriceError(address asset);

    /// @notice Initialize the oracle
    /// @param authority The access manager address
    function initialize(address authority) external;

    /// @notice Set the source chain for an asset
    /// @dev New sources must produce a non-zero price
    /// @param asset The asset the chain prices
    /// @param sources The hops to multiply, each with a primary and optional secondary
    function setSource(address asset, Sources[] calldata sources) external;

    /// @notice Get the price for a configured asset
    /// @dev Zero if nothing is configured or a hop cannot answer.
    /// @param asset The asset to price
    /// @return latestAnswer The composed price in 18 decimals, or zero
    function price(address asset) external view returns (uint256 latestAnswer);

    /// @notice Get the price of a chain without reading storage
    /// @param sources The hops to multiply
    /// @return latestAnswer The composed price in 18 decimals, or zero
    function price(Sources[] calldata sources) external view returns (uint256 latestAnswer);

    /// @notice Get the source chain for an asset
    /// @param asset The asset to look up
    /// @return sourceChain The hops in order
    function sources(address asset) external view returns (Sources[] memory sourceChain);
}
