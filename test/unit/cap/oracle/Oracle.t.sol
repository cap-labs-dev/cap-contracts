// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { MockAdapter, MockAggregator } from "./MockChainlinkFeeds.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Unit tests for the oracle every price in the protocol is read through.
///
/// A derived price is a chain of assets, each priced on its own entries, so this is where that
/// shape is tested: that the legs multiply, that the stalest link sets the timestamp, that each
/// leg is measured against its own window rather than one window covering the chain, and that a
/// leg falls to its own backup without disturbing the legs either side of it.
contract OracleTest is Test {
    uint256 internal constant ONE = 1e8;

    Oracle internal oracle;
    AccessManager internal accessManager;
    ChainlinkAdapter internal chainlink;

    address internal admin = makeAddr("admin");

    // named for the canonical derived price: wstETH is a rate against stETH, and stETH has a feed
    address internal wsteth = makeAddr("wstETH");
    address internal steth = makeAddr("stETH");

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(admin);
        chainlink = new ChainlinkAdapter();

        Oracle implem = new Oracle();
        oracle = Oracle(
            address(new ERC1967Proxy(address(implem), abi.encodeCall(Oracle.initialize, (address(accessManager)))))
        );

        // the setters are `restricted`, and only the admin holds a role by default
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = Oracle.setSource.selector;
        selectors[1] = Oracle.setBackup.selector;
        selectors[2] = Oracle.setChain.selector;
        accessManager.setTargetFunctionRole(address(oracle), selectors, accessManager.ADMIN_ROLE());
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _entry(address adapter, bytes memory payload, uint256 staleness)
        internal
        pure
        returns (IOracle.OracleData memory)
    {
        return IOracle.OracleData({ adapter: adapter, payload: payload, staleness: staleness });
    }

    /// @dev An entry answering a fixed value, for exercising the oracle without a feed behind it
    function _stub(uint256 answer, uint256 updatedAt, uint256 staleness) internal returns (IOracle.OracleData memory) {
        MockAdapter a = new MockAdapter(answer, updatedAt);
        return _entry(address(a), abi.encodeCall(MockAdapter.price, ()), staleness);
    }

    function _setSource(address asset, IOracle.OracleData memory data) internal {
        vm.prank(admin);
        oracle.setSource(asset, data);
    }

    function _setBackup(address asset, IOracle.OracleData memory data) internal {
        vm.prank(admin);
        oracle.setBackup(asset, data);
    }

    function _setChain(address asset, address[] memory assets) internal {
        vm.prank(admin);
        oracle.setChain(asset, assets);
    }

    function _assets(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _assets(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    // ── an asset priced on its own entries ────────────────────────────────────

    function test_price_readsAnAssetWithNoChainFromItsOwnSource() public {
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));

        (uint256 answer, uint256 updatedAt) = oracle.price(steth);

        assertEq(answer, 2000e8, "answered as posted, with no rounding on the way through");
        assertEq(updatedAt, block.timestamp, "and carries its own stamp");
    }

    /// @dev End to end through the real adapter rather than a stub, so the payload built with
    /// abi.encodeCall and the return decode are checked against each other.
    function test_price_readsAChainlinkFeedThroughTheRealAdapter() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        _setSource(steth, _entry(address(chainlink), abi.encodeCall(ChainlinkAdapter.price, (address(feed))), 1 hours));

        (uint256 answer, uint256 updatedAt) = oracle.price(steth);

        assertEq(answer, 2000e8, "read through the adapter");
        assertEq(updatedAt, block.timestamp, "stamped by the feed");
    }

    /// @dev The convention that holds the whole thing together, and the one thing composing here
    /// puts at risk: legs are multiplied, so an adapter answering in a different scale moves the
    /// composed price by whole orders of magnitude with nothing to catch it. Pinned behaviourally
    /// rather than by reading the adapter's own constant, which is private, so the two drifting
    /// apart fails here rather than silently repricing every asset.
    function test_theAdapterAnswersInTheScaleTheOracleComposesIn() public {
        MockAggregator feed = new MockAggregator(8, 1e8, block.timestamp);
        _setSource(steth, _entry(address(chainlink), abi.encodeCall(ChainlinkAdapter.price, (address(feed))), 1 hours));

        (uint256 answer,) = oracle.price(steth);

        assertEq(oracle.DECIMALS(), 8, "the documented scale");
        assertEq(answer, 10 ** oracle.DECIMALS(), "a price of one reads as one in the oracle's own scale");
    }

    // ── chains ────────────────────────────────────────────────────────────────

    /// @dev The shape governance is expected to configure, and the reason a chain may name the
    /// asset it prices: the wstETH source holds the rate against stETH, and the chain says to
    /// compose that rate with whatever stETH itself is worth. Legs are priced from their own
    /// entries and never through their own chain, so this is not recursion.
    function test_price_composesAnAssetsOwnRateWithTheAssetItIsARateOf() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        (uint256 answer,) = oracle.price(wsteth);

        assertEq(answer, 2100e8, "two thousand at one and a bit");
    }

    /// @dev The point of naming assets rather than repeating adapter calls in each chain. The
    /// stETH feed is configured once and both chains read the same entry, so moving it moves
    /// everything derived from it at once instead of leaving copies behind.
    function test_price_sharesOneAssetsEntryAcrossEveryChainThatNamesIt() public {
        address wbeth = makeAddr("wBETH");
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(wbeth, _stub(1.02e8, block.timestamp, 1 days));
        _setChain(wsteth, _assets(wsteth, steth));
        _setChain(wbeth, _assets(wbeth, steth));

        (uint256 firstBefore,) = oracle.price(wsteth);
        (uint256 secondBefore,) = oracle.price(wbeth);
        assertEq(firstBefore, 2100e8, "the rate against the shared price");
        assertEq(secondBefore, 2040e8, "and the other rate against the same one");

        // repoint stETH alone
        _setSource(steth, _stub(2500e8, block.timestamp, 1 hours));

        (uint256 firstAfter,) = oracle.price(wsteth);
        (uint256 secondAfter,) = oracle.price(wbeth);
        assertEq(firstAfter, 2625e8, "moved with the shared entry");
        assertEq(secondAfter, 2550e8, "and so did the other, from the one edit");
    }

    /// @dev A chain is only as fresh as its stalest link, so the oldest stamp has to be the one
    /// that comes back for any consumer measuring against it.
    function test_price_reportsTheOldestStampAcrossTheChain() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp - 500, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp - 10, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        (, uint256 updatedAt) = oracle.price(wsteth);

        assertEq(updatedAt, block.timestamp - 500, "the stalest link sets the stamp");
    }

    /// @dev Composing must not overflow on an intermediate product the division afterwards would
    /// have brought back into range, which a plain multiply would.
    function test_price_composesLargeAnswersWithoutOverflowing() public {
        uint256 huge = 2 ** 129;
        _setSource(wsteth, _stub(huge, block.timestamp, 1 hours));
        _setSource(steth, _stub(huge, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        (uint256 answer,) = oracle.price(wsteth);

        // spelled out rather than recomputed, since the obvious expression overflows in the test
        // exactly as it would in the contract, and reusing mulDiv here would only check mulDiv
        // against itself
        assertEq(
            answer,
            4_631_683_569_492_647_816_942_839_400_347_516_314_130_799_386_625_622_561_578_303_360_316_525,
            "the full product, not a revert"
        );
    }

    /// @dev Order does not matter to the result beyond a wei of truncation, which is worth pinning
    /// because the composition truncates once per leg.
    function test_price_isOrderIndependentUpToTruncation() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));

        _setChain(wsteth, _assets(wsteth, steth));
        (uint256 forwards,) = oracle.price(wsteth);

        _setChain(wsteth, _assets(steth, wsteth));
        (uint256 backwards,) = oracle.price(wsteth);

        assertApproxEqAbs(forwards, backwards, 1, "the same price either way round");
    }

    // ── per-leg staleness, which naming assets gets for free ──────────────────

    /// @dev One window across a whole chain would have to be loose enough for the slowest leg,
    /// which is exactly the freshness the fastest leg should not be given. A rate that creeps and
    /// a spot price that moves every block get their own windows because each is the asset's own.
    function test_price_measuresEachLegAgainstItsOwnWindow() public {
        // the rate may be a day old, the spot price only a minute
        _setSource(wsteth, _stub(1.05e8, block.timestamp - 12 hours, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp, 1 minutes));
        _setChain(wsteth, _assets(wsteth, steth));

        (uint256 answer,) = oracle.price(wsteth);
        assertEq(answer, 2100e8, "a half-day-old rate is fine against a day-long window");

        // now let only the spot leg go stale, well inside the rate leg's window
        vm.warp(block.timestamp + 2 minutes);

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(wsteth);
    }

    function test_price_refusesAnAssetWhoseOnlySourceIsStale() public {
        _setSource(steth, _stub(2000e8, block.timestamp - 2 hours, 1 hours));

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(steth);
    }

    /// @dev A stamp ahead of the block is not old, and the subtraction must not panic on it, since
    /// that would take the backup down rather than falling to it.
    function test_price_toleratesAnAnswerStampedInTheFuture() public {
        _setSource(steth, _stub(2000e8, block.timestamp + 1 hours, 1 minutes));

        (uint256 answer,) = oracle.price(steth);

        assertEq(answer, 2000e8, "not stale, and not a panic either");
    }

    // ── falling through to the backup ─────────────────────────────────────────

    function test_price_fallsToTheBackupWhenTheSourceIsStale() public {
        _setSource(steth, _stub(2000e8, block.timestamp - 2 hours, 1 hours));
        _setBackup(steth, _stub(1990e8, block.timestamp, 1 hours));

        (uint256 answer,) = oracle.price(steth);

        assertEq(answer, 1990e8, "answered from the backup");
    }

    /// @dev What naming assets buys on the failure path: the broken leg reaches for its own backup
    /// and the legs either side of it are untouched, where one backup chain covering the whole
    /// composition would have had to restate the working legs as well.
    function test_price_fallsToOneLegsBackupWithoutDisturbingTheRest() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp - 2 hours, 1 hours));
        _setBackup(steth, _stub(1990e8, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        (uint256 answer,) = oracle.price(wsteth);

        assertEq(answer, 2089.5e8, "the rate leg's own source against the spot leg's backup");
    }

    /// @dev The failure that would otherwise take the backup with it. A staticcall to an account
    /// with no code succeeds and returns nothing, and an unset entry names address(0), so decoding
    /// straight through would revert rather than report no price.
    function test_price_fallsToTheBackupWhenTheSourceAdapterHasNoCode() public {
        _setSource(steth, _entry(makeAddr("nothing here"), abi.encodeCall(MockAdapter.price, ()), 1 hours));
        _setBackup(steth, _stub(1990e8, block.timestamp, 1 hours));

        (uint256 answer,) = oracle.price(steth);

        assertEq(answer, 1990e8, "the dead source did not take the backup with it");
    }

    function test_price_fallsToTheBackupWhenTheSourceAdapterReverts() public {
        MockAdapter broken = new MockAdapter(2000e8, block.timestamp);
        broken.setReverts(true);
        _setSource(steth, _entry(address(broken), abi.encodeCall(MockAdapter.price, ()), 1 hours));
        _setBackup(steth, _stub(1990e8, block.timestamp, 1 hours));

        (uint256 answer,) = oracle.price(steth);

        assertEq(answer, 1990e8, "answered from the backup");
    }

    /// @dev A rate-style adapter answering a value with no timestamp returns one word. That has to
    /// be refused rather than decoded, which is what the length check is for.
    function test_price_refusesAnAdapterThatAnswersWithoutATimestamp() public {
        MockAdapter short = new MockAdapter(2000e8, block.timestamp);
        _setSource(steth, _entry(address(short), abi.encodeCall(MockAdapter.shortPrice, ()), 1 hours));

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(steth);
    }

    function test_price_refusesAnAssetWithNothingConfiguredAtAll() public {
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(steth);
    }

    function test_price_refusesWhenBothTheSourceAndTheBackupFail() public {
        _setSource(steth, _stub(0, block.timestamp, 1 hours));
        _setBackup(steth, _stub(0, block.timestamp, 1 hours));

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(steth);
    }

    /// @dev Legs that each answer something can still multiply down to nothing, and zero is what
    /// no price means everywhere else in here, so it cannot be handed back as one.
    function test_price_refusesAChainThatComposesToZero() public {
        // a wei each, whose product truncates away entirely
        _setSource(wsteth, _stub(1, block.timestamp, 1 hours));
        _setSource(steth, _stub(1, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, wsteth));
        oracle.price(wsteth);
    }

    /// @dev The failing leg is the actionable part, not the asset that was asked for, so a chain
    /// with an unconfigured leg names the leg.
    function test_price_namesTheFailingLegRatherThanTheAssetAskedFor() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setChain(wsteth, _assets(wsteth, steth));

        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(wsteth);
    }

    // ── configuration ─────────────────────────────────────────────────────────

    /// @dev Caught where someone is looking. Zero admits only an answer written in the calling
    /// block, so it cannot be told apart from never having been configured, and the read it
    /// reverts on is inside a health check or a redemption rather than here.
    function test_setSource_rejectsAnEntryWithNoStalenessWindow() public {
        MockAdapter a = new MockAdapter(2000e8, block.timestamp);
        IOracle.OracleData memory data = _entry(address(a), abi.encodeCall(MockAdapter.price, ()), 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOracle.NoStaleness.selector, steth));
        oracle.setSource(steth, data);
    }

    function test_setBackup_rejectsAnEntryWithNoStalenessWindow() public {
        MockAdapter a = new MockAdapter(2000e8, block.timestamp);
        IOracle.OracleData memory data = _entry(address(a), abi.encodeCall(MockAdapter.price, ()), 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOracle.NoStaleness.selector, steth));
        oracle.setBackup(steth, data);
    }

    /// @dev An empty entry is a deliberate clearing and carries no window to check, so the guard
    /// must not stand in the way of removing a feed.
    function test_setSource_canClearAnEntry() public {
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));

        _setSource(steth, _entry(address(0), "", 0));

        assertEq(oracle.source(steth).adapter, address(0), "cleared");
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.price(steth);
    }

    /// @dev A leg of zero has no entries and never will, so it would compose in as a zero and take
    /// the whole chain down on every read.
    function test_setChain_rejectsTheZeroAsset() public {
        address[] memory legs = _assets(wsteth, address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOracle.InvalidChainAsset.selector, wsteth, 1));
        oracle.setChain(wsteth, legs);
    }

    /// @dev Shortening a chain must not leave the tail of the old one behind, still being priced
    /// against legs nobody meant to keep.
    function test_setChain_replacingAChainDropsTheOldTail() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));
        assertEq(oracle.chain(wsteth).length, 2, "two legs to begin with");

        _setChain(wsteth, _assets(steth));

        assertEq(oracle.chain(wsteth).length, 1, "and one afterwards");
        (uint256 answer,) = oracle.price(wsteth);
        assertEq(answer, 2000e8, "priced on the new chain alone, with the rate leg dropped");
    }

    /// @dev Clearing a chain falls back to the asset's own entries rather than leaving it
    /// unpriceable, which is what makes a chain an addition rather than the only way in.
    function test_setChain_clearingAChainReturnsToTheAssetsOwnSource() public {
        _setSource(wsteth, _stub(1.05e8, block.timestamp, 1 days));
        _setSource(steth, _stub(2000e8, block.timestamp, 1 hours));
        _setChain(wsteth, _assets(wsteth, steth));

        _setChain(wsteth, new address[](0));

        assertEq(oracle.chain(wsteth).length, 0, "cleared");
        (uint256 answer,) = oracle.price(wsteth);
        assertEq(answer, 1.05e8, "the bare rate, uncomposed");
    }

    /// @dev The getters are hand-written, because the one Solidity generates for a mapping to a
    /// struct returns the members one by one and drops the dynamic ones. An entry handed back
    /// without its payload would look configured and be uncallable, so both are read back whole.
    function test_setSource_roundTripsThePayloadAndWindow() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        bytes memory payload = abi.encodeCall(ChainlinkAdapter.price, (address(feed)));
        _setSource(steth, _entry(address(chainlink), payload, 3 hours));

        IOracle.OracleData memory read = oracle.source(steth);

        assertEq(read.adapter, address(chainlink), "adapter kept");
        assertEq(keccak256(read.payload), keccak256(payload), "payload kept whole, dynamic member and all");
        assertEq(read.staleness, 3 hours, "window kept");
    }

    function test_setBackup_roundTripsThePayloadAndWindow() public {
        MockAggregator feed = new MockAggregator(8, 1990e8, block.timestamp);
        bytes memory payload = abi.encodeCall(ChainlinkAdapter.price, (address(feed)));
        _setBackup(steth, _entry(address(chainlink), payload, 3 hours));

        IOracle.OracleData memory read = oracle.backup(steth);

        assertEq(read.adapter, address(chainlink), "adapter kept");
        assertEq(keccak256(read.payload), keccak256(payload), "payload kept whole, dynamic member and all");
        assertEq(read.staleness, 3 hours, "window kept");
        assertEq(oracle.source(steth).adapter, address(0), "and the source was left alone");
    }

    function test_setChain_roundTripsTheAssetsInOrder() public {
        _setChain(wsteth, _assets(wsteth, steth));

        address[] memory read = oracle.chain(wsteth);

        assertEq(read.length, 2, "both legs");
        assertEq(read[0], wsteth, "first as given");
        assertEq(read[1], steth, "second as given");
    }

    function test_setSource_onlyAuthority() public {
        IOracle.OracleData memory data = _stub(2000e8, block.timestamp, 1 hours);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        oracle.setSource(steth, data);
    }

    function test_setBackup_onlyAuthority() public {
        IOracle.OracleData memory data = _stub(2000e8, block.timestamp, 1 hours);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        oracle.setBackup(steth, data);
    }

    function test_setChain_onlyAuthority() public {
        address[] memory legs = _assets(wsteth, steth);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        oracle.setChain(wsteth, legs);
    }
}
