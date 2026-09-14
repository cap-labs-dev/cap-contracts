// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Oracle
/// @author kexley, Cap Labs
/// @notice Unified price and rate oracle
/// @dev A chain of hops, each with a primary and optional secondary feed. Prices are in 18 decimals.
///      Stale or unusable reads are zero; the caller decides whether that is an error.
interface IOracle {
    /// @notice Fixed-point scale every adapter answers in (18, matching cUSD)
    /// @return decimals Answer decimals
    function DECIMALS() external view returns (uint8 decimals);

    /// @notice Primary and secondary source data for one hop
    /// @param primary Primary source
    /// @param secondary Secondary source, used when the primary cannot answer
    struct Sources {
        Source primary;
        Source secondary;
    }

    /// @notice Specific data for a source
    /// @param adapter Adapter returning exactly `(uint256 price, uint256 lastUpdated)`
    /// @param payload Encoded call to the adapter
    /// @param staleness Maximum age of the answer, in seconds
    struct Source {
        address adapter;
        bytes payload;
        uint256 staleness;
    }

    /// @dev Set the source chain for an asset
    event SetSource(address asset, Sources[] sources);

    /// @dev No usable price for this asset
    error PriceError(address asset);

    /// @notice Initialize the oracle
    /// @param _authority Authority address
    function initialize(address _authority) external;

    /// @notice Set the source chain for an asset
    /// @dev New sources must produce a non-zero price
    /// @param _asset Asset the chain prices
    /// @param _sources Hops to multiply, each with a primary and optional secondary
    function setSource(address _asset, Sources[] calldata _sources) external;

    /// @notice Price for a configured asset
    /// @dev Zero if nothing is configured or a hop cannot answer.
    /// @param _asset Asset to price
    /// @return latestAnswer Composed price in {DECIMALS}, or zero
    function price(address _asset) external view returns (uint256 latestAnswer);

    /// @notice Price a chain without reading storage
    /// @param _sources Hops to multiply
    /// @return latestAnswer Composed price in {DECIMALS}, or zero
    function price(Sources[] calldata _sources) external view returns (uint256 latestAnswer);

    /// @notice Source chain for an asset
    /// @param _asset Asset to look up
    /// @return sourceChain Hops in order
    function sources(address _asset) external view returns (Sources[] memory sourceChain);
}
