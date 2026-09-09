// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IChainlink } from "../../interfaces/IChainlink.sol";

/// @title Chainlink Adapter
/// @author kexley, Cap Labs
/// @notice Prices are sourced from Chainlink
///
/// One feed, one leg. Composing a derived price is {Oracle}'s job, not this contract's: the legs of
/// a real chain come from different adapters, so chaining in here could only ever chain Chainlink
/// to Chainlink, and each leg would lose the staleness window that suits how often it moves.
///
/// A contract rather than a library, so a caller can build the payload {Oracle} holds with
/// `abi.encodeCall` and have the compiler check it against this signature. `abi.encodeCall`
/// refuses library functions outright, which leaves `abi.encodeWithSignature` and a string to
/// mistype. That mistake compiles, deploys, and then fails every staticcall for the life of the
/// configuration, which {Oracle-price} reads as no price and quietly answers from the backup.
///
/// Stateless and view-only, so one deployment serves every feed and each {IOracle-OracleData}
/// carries only the feed to read.
///
/// Refuses rather than returning zero on a feed it does not trust. {Oracle-price} treats a revert
/// and a zero identically, so within the protocol the choice costs nothing, but it names which
/// feed failed and why for anything reading the adapter directly.
contract ChainlinkAdapter {
    /// @dev Answers are normalised to this many decimals, matching {IOracle-DECIMALS}
    uint8 private constant DECIMALS = 8;

    /// @dev The round has not settled, which Chainlink signals with a zero timestamp
    error IncompleteRound(address source);

    /// @dev The feed reported zero or below, which is a broken feed rather than a cheap asset
    error NonPositiveAnswer(address source, int256 answer);

    /// @dev The answer is resting on one of the aggregator's bounds, so it is a clamp not a price
    error AtCircuitBreaker(address source, int256 answer);

    /// @notice Fetch the price from a Chainlink feed, normalised to 8 decimals
    /// @param _source Chainlink feed
    /// @return latestAnswer Price of the asset fixed to 8 decimals
    /// @return lastUpdated When the feed last wrote an answer
    function price(address _source) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        int256 answer;
        (, answer,, lastUpdated,) = IChainlink(_source).latestRoundData();

        // A round that has not settled carries a zero timestamp and an answer Chainlink documents
        // as not yet meaningful. Left alone it passes on as a price stamped at the unix epoch,
        // which only fails closed because the staleness check upstream measures against that stamp
        if (lastUpdated == 0) revert IncompleteRound(_source);
        if (answer <= 0) revert NonPositiveAnswer(_source, answer);
        if (!_withinBounds(_source, answer)) revert AtCircuitBreaker(_source, answer);

        latestAnswer = uint256(answer);

        // Read after the checks so a feed already known to be bad does not pay for the extra call.
        // It cannot be cached despite being immutable per aggregator, because the only path in
        // here is a staticcall from {Oracle-price} and nothing on it may write
        uint8 decimals = IChainlink(_source).decimals();
        if (decimals < DECIMALS) latestAnswer *= 10 ** (DECIMALS - decimals);
        if (decimals > DECIMALS) latestAnswer /= 10 ** (decimals - DECIMALS);
    }

    /// @dev Whether the answer sits strictly inside the aggregator's reportable range.
    ///
    /// An aggregator clamps to `minAnswer` or `maxAnswer` rather than reporting through them, and
    /// it keeps publishing that clamped figure on a fresh timestamp, so no staleness check catches
    /// it. Collateral that has crashed past the floor goes on being valued at the floor, which
    /// keeps a market borrowing and out of reach of liquidation. This is how Venus and Blizz were
    /// drained during the LUNA collapse.
    ///
    /// The bounds sit on the aggregator behind the proxy and not every feed exposes either hop, so
    /// a missing one is read as no bounds published and waved through rather than treated as a
    /// failure. Fail-open is deliberate: closing would make perfectly serviceable feeds unusable,
    /// and it leaves those feeds exactly where they were before this check existed.
    /// @param _source Chainlink feed
    /// @param _answer The answer being checked
    /// @return within True when the answer is inside the range, or no range is published
    function _withinBounds(address _source, int256 _answer) private view returns (bool within) {
        (bool success, bytes memory returnedData) = _source.staticcall(abi.encodeCall(IChainlink.aggregator, ()));
        if (!success || returnedData.length < 32) return true;
        address aggregator = abi.decode(returnedData, (address));

        (success, returnedData) = aggregator.staticcall(abi.encodeCall(IChainlink.minAnswer, ()));
        if (!success || returnedData.length < 32) return true;
        int256 minAnswer = abi.decode(returnedData, (int192));

        (success, returnedData) = aggregator.staticcall(abi.encodeCall(IChainlink.maxAnswer, ()));
        if (!success || returnedData.length < 32) return true;
        int256 maxAnswer = abi.decode(returnedData, (int192));

        // Strict, because the failure being caught is an answer resting exactly on a bound
        within = _answer > minAnswer && _answer < maxAnswer;
    }
}
