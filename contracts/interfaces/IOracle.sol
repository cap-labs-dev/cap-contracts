// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Oracle
/// @author kexley, Cap Labs
/// @notice Price and rate oracles are unified
///
/// Every asset is priced by its own source, falling back to its own backup when the source cannot
/// answer. An asset whose price is derived from others also carries a chain: a list of assets to
/// price in turn and multiply together, so wstETH is the wstETH-to-stETH rate composed with the
/// stETH price.
///
/// A chain names assets rather than carrying adapter calls of its own, so the feed for stETH is
/// configured once and every chain that passes through stETH refers to it. Repeating the payload
/// in each chain would leave the same feed configured in several places and only some of them
/// updated when it moves. It also means each leg brings its own backup and its own staleness
/// window along with it, rather than one of each covering a whole chain — which matters, because a
/// window wide enough for a rate that creeps is far too wide for a spot price that moves.
///
/// Chain legs are priced directly from their own source and backup, never through their own chain.
/// That is what makes it safe for an asset to appear in its own chain, which is the natural way to
/// configure a derived price: the wstETH source holds the ratio, and the wstETH chain is wstETH
/// followed by stETH.
///
/// Every adapter answers in {DECIMALS} fixed point and returns the point its answer was written.
/// The convention is not negotiable per adapter: legs are multiplied together, so one answering in
/// a different scale moves the composed price by whole orders of magnitude with nothing to catch
/// it. Adapters are also read by staticcall, so nothing an adapter does may write.
interface IOracle {
    /// @notice Fixed point scale every adapter answers in, and the scale of a composed price
    /// @return decimals Answer decimals
    function DECIMALS() external view returns (uint8 decimals);

    /// @notice How to reach a price for one asset
    /// @param adapter Adapter to call, or zero for no entry at all
    /// @param payload Encoded call to the adapter, including everything it needs
    /// @param staleness How old this answer may be, in seconds
    struct OracleData {
        address adapter;
        bytes payload;
        uint256 staleness;
    }

    /// @dev Set the source for an asset
    event SetSource(address asset, OracleData data);

    /// @dev Set the backup for an asset
    event SetBackup(address asset, OracleData data);

    /// @dev Set the chain composing an asset's price
    event SetChain(address asset, address[] assets);

    /// @dev Neither the source nor the backup could answer for the asset. When a chain is being
    /// composed this names the leg that failed rather than the asset asked for, since the leg is
    /// the part anyone can act on
    error PriceError(address asset);

    /// @dev An entry names an adapter but no staleness window. Zero admits only an answer written
    /// in the calling block, so it is indistinguishable from never having been configured
    error NoStaleness(address asset);

    /// @dev A chain names the zero address, which can never be priced
    error InvalidChainAsset(address asset, uint256 index);

    /// @notice Initialize the oracle
    /// @param _authority Authority address
    function initialize(address _authority) external;

    /// @notice Set the source for an asset, replacing whatever was there
    /// @param _asset Asset the entry prices
    /// @param _data Adapter, payload and window, or an empty entry to clear
    function setSource(address _asset, OracleData calldata _data) external;

    /// @notice Set the backup for an asset, replacing whatever was there
    /// @param _asset Asset the entry prices
    /// @param _data Adapter, payload and window, or an empty entry to clear
    function setBackup(address _asset, OracleData calldata _data) external;

    /// @notice Set the chain composing an asset's price, replacing whatever was there
    /// @param _asset Asset the chain prices
    /// @param _assets Assets to price and multiply, in order, or empty to price `_asset` on its
    /// own source and backup alone
    function setChain(address _asset, address[] calldata _assets) external;

    /// @notice Price for an asset, from its chain if it has one and its own entries if not
    /// @param _asset Asset to price
    /// @return latestAnswer Composed price in {DECIMALS} fixed point
    /// @return lastUpdated Oldest write across the legs, since a chain is only as fresh as its
    /// stalest link
    function price(address _asset) external view returns (uint256 latestAnswer, uint256 lastUpdated);

    /// @notice Source entry for the asset
    /// @param _asset Asset to get the source for
    /// @return data Adapter, payload and window
    function source(address _asset) external view returns (OracleData memory data);

    /// @notice Backup entry for the asset
    /// @param _asset Asset to get the backup for
    /// @return data Adapter, payload and window
    function backup(address _asset) external view returns (OracleData memory data);

    /// @notice Chain composing the asset's price, empty when it is priced on its own entries
    /// @param _asset Asset to get the chain for
    /// @return assets Assets priced and multiplied, in order
    function chain(address _asset) external view returns (address[] memory assets);
}
