// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { MockAdapter, MockAggregator } from "../../../shared/mocks/MockChainlinkFeeds.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Unit tests for the oracle every price in the protocol is read through.
///
/// Each hop has a primary and optional secondary. Stale or unusable reads are zero; the oracle
/// does not revert on a missing price. Hops are multiplied to compose a derived price.
contract OracleTest is Test {
    Oracle internal oracle;
    AccessManager internal accessManager;
    address internal chainlink;

    address internal admin = makeAddr("admin");

    address internal wsteth = makeAddr("wstETH");
    address internal steth = makeAddr("stETH");

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(admin);
        bytes memory adapterCode = type(ChainlinkAdapter).creationCode;
        address adapter;
        assembly {
            adapter := create(0, add(adapterCode, 0x20), mload(adapterCode))
        }
        chainlink = adapter;

        Oracle implem = new Oracle();
        oracle = Oracle(
            address(new ERC1967Proxy(address(implem), abi.encodeCall(Oracle.initialize, (address(accessManager)))))
        );

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Oracle.setSource.selector;
        accessManager.setTargetFunctionRole(address(oracle), selectors, accessManager.ADMIN_ROLE());
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _source(address adapter, bytes memory payload, uint256 staleness)
        internal
        pure
        returns (IOracle.Source memory)
    {
        return IOracle.Source({ adapter: adapter, payload: payload, staleness: staleness });
    }

    function _stub(uint256 answer, uint256 updatedAt, uint256 staleness) internal returns (IOracle.Source memory) {
        MockAdapter a = new MockAdapter(answer, updatedAt);
        return _source(address(a), abi.encodeCall(MockAdapter.price, ()), staleness);
    }

    function _hop(IOracle.Source memory primary) internal pure returns (IOracle.Sources memory) {
        return IOracle.Sources({ primary: primary, secondary: IOracle.Source(address(0), "", 0) });
    }

    function _hop(IOracle.Source memory primary, IOracle.Source memory secondary)
        internal
        pure
        returns (IOracle.Sources memory)
    {
        return IOracle.Sources({ primary: primary, secondary: secondary });
    }

    function _chain(IOracle.Sources memory a) internal pure returns (IOracle.Sources[] memory hops) {
        hops = new IOracle.Sources[](1);
        hops[0] = a;
    }

    function _chain(IOracle.Sources memory a, IOracle.Sources memory b)
        internal
        pure
        returns (IOracle.Sources[] memory hops)
    {
        hops = new IOracle.Sources[](2);
        hops[0] = a;
        hops[1] = b;
    }

    function _chain(IOracle.Sources memory a, IOracle.Sources memory b, IOracle.Sources memory c)
        internal
        pure
        returns (IOracle.Sources[] memory hops)
    {
        hops = new IOracle.Sources[](3);
        hops[0] = a;
        hops[1] = b;
        hops[2] = c;
    }

    function _set(address asset, IOracle.Sources[] memory hops) internal {
        vm.prank(admin);
        oracle.setSource(asset, hops);
    }

    // ── a single hop ──────────────────────────────────────────────────────────

    function test_price_readsAPrimarySource() public {
        _set(steth, _chain(_hop(_stub(2000e18, block.timestamp, 1 hours))));

        assertEq(oracle.price(steth), 2000e18, "answered as posted");
    }

    function test_price_readsAChainlinkFeedThroughTheRealAdapter() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        _set(
            steth,
            _chain(
                _hop(
                    _source(chainlink, abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)), 1 hours)
                )
            )
        );

        assertEq(oracle.price(steth), 2000e18, "read through the adapter");
    }

    function test_theAdapterAnswersInTheScaleTheOracleComposesIn() public {
        MockAggregator feed = new MockAggregator(8, 1e8, block.timestamp);
        _set(
            steth,
            _chain(
                _hop(
                    _source(chainlink, abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)), 1 hours)
                )
            )
        );

        assertEq(oracle.DECIMALS(), 18, "the documented scale");
        assertEq(oracle.price(steth), 10 ** oracle.DECIMALS(), "a price of one reads as one in the oracle's own scale");
    }

    function test_price_previewMatchesTheStoredChain() public {
        IOracle.Sources[] memory hops = _chain(_hop(_stub(2000e18, block.timestamp, 1 hours)));

        assertEq(oracle.price(hops), 2000e18, "priced without storing");
        _set(steth, hops);
        assertEq(oracle.price(steth), 2000e18, "and the same after it is stored");
    }

    // ── composing hops ────────────────────────────────────────────────────────

    function test_price_multipliesHops() public {
        _set(
            wsteth,
            _chain(_hop(_stub(1.05e18, block.timestamp, 1 days)), _hop(_stub(2000e18, block.timestamp, 1 hours)))
        );

        assertEq(oracle.price(wsteth), 2100e18, "two thousand at one and a bit");
    }

    function test_price_sharesOneAdapterAcrossAssets() public {
        address wbeth = makeAddr("wBETH");
        IOracle.Source memory usd = _stub(2000e18, block.timestamp, 1 hours);
        _set(wsteth, _chain(_hop(_stub(1.05e18, block.timestamp, 1 days)), _hop(usd)));
        _set(wbeth, _chain(_hop(_stub(1.02e18, block.timestamp, 1 days)), _hop(usd)));

        assertEq(oracle.price(wsteth), 2100e18);
        assertEq(oracle.price(wbeth), 2040e18);

        MockAdapter(usd.adapter).set(2500e18, block.timestamp);

        assertEq(oracle.price(wsteth), 2625e18, "moved with the shared adapter");
        assertEq(oracle.price(wbeth), 2550e18, "and so did the other");
    }

    function test_price_composesLargeAnswersWithoutOverflowing() public {
        uint256 huge = 2 ** 129;
        _set(wsteth, _chain(_hop(_stub(huge, block.timestamp, 1 hours)), _hop(_stub(huge, block.timestamp, 1 hours))));

        assertEq(
            oracle.price(wsteth),
            463_168_356_949_264_781_694_283_940_034_751_631_413_079_938_662_562_256_157_830,
            "the full product, not a revert"
        );
    }

    function test_price_isOrderIndependentUpToTruncation() public {
        IOracle.Sources memory usd = _hop(_stub(2000e18, block.timestamp, 1 hours));
        IOracle.Sources memory haircut = _hop(_stub(1.01e18, block.timestamp, 1 hours));

        _set(wsteth, _chain(usd, haircut));
        uint256 forwards = oracle.price(wsteth);

        _set(wsteth, _chain(haircut, usd));
        uint256 backwards = oracle.price(wsteth);

        assertApproxEqAbs(forwards, backwards, 1, "the same price either way round");
    }

    // ── staleness: oracle returns zero, it does not revert ────────────────────

    function test_price_fallsToTheSecondaryWhenThePrimaryIsStale() public {
        _set(
            steth,
            _chain(_hop(_stub(2000e18, block.timestamp - 2 hours, 1 hours), _stub(1990e18, block.timestamp, 1 hours)))
        );

        assertEq(oracle.price(steth), 1990e18, "answered from the secondary");
    }

    function test_price_returnsZeroWhenBothFeedsAreStale() public {
        _set(steth, _chain(_hop(_stub(2000e18, block.timestamp, 1 hours), _stub(1990e18, block.timestamp, 1 hours))));

        vm.warp(block.timestamp + 2 hours);
        assertEq(oracle.price(steth), 0, "both unusable");
    }

    function test_price_returnsZeroWhenNothingIsConfigured() public view {
        assertEq(oracle.price(steth), 0);
    }

    function test_price_returnsZeroWhenAHopCannotAnswer() public {
        IOracle.Source memory usd = _stub(2000e18, block.timestamp, 1 hours);
        _set(wsteth, _chain(_hop(_stub(1.05e18, block.timestamp, 1 days)), _hop(usd)));

        MockAdapter(usd.adapter).set(0, block.timestamp);
        assertEq(oracle.price(wsteth), 0, "a dead hop zeros the product");
    }

    function test_price_returnsZeroWhenTheProductTruncatesAway() public {
        IOracle.Sources[] memory hops =
            _chain(_hop(_stub(1, block.timestamp, 1 hours)), _hop(_stub(1, block.timestamp, 1 hours)));

        assertEq(oracle.price(hops), 0, "wei * wei / 1e18");
    }

    function test_price_measuresEachHopAgainstItsOwnWindow() public {
        _set(
            wsteth,
            _chain(
                _hop(_stub(1.05e18, block.timestamp - 12 hours, 1 days)),
                _hop(_stub(2000e18, block.timestamp, 1 minutes))
            )
        );

        assertEq(oracle.price(wsteth), 2100e18, "a half-day-old rate is fine against a day-long window");

        vm.warp(block.timestamp + 2 minutes);
        assertEq(oracle.price(wsteth), 0, "the USD hop went stale");
    }

    function test_price_toleratesAnAnswerStampedInTheFuture() public {
        _set(steth, _chain(_hop(_stub(2000e18, block.timestamp + 1 hours, 1 minutes))));

        assertEq(oracle.price(steth), 2000e18, "not stale, and not a panic either");
    }

    function test_price_fallsToTheSecondaryWhenThePrimaryAdapterHasNoCode() public {
        _set(
            steth,
            _chain(
                _hop(
                    _source(makeAddr("nothing here"), abi.encodeCall(MockAdapter.price, ()), 1 hours),
                    _stub(1990e18, block.timestamp, 1 hours)
                )
            )
        );

        assertEq(oracle.price(steth), 1990e18, "the dead primary did not take the secondary with it");
    }

    function test_price_fallsToTheSecondaryWhenThePrimaryAdapterReverts() public {
        MockAdapter broken = new MockAdapter(2000e18, block.timestamp);
        broken.setReverts(true);
        _set(
            steth,
            _chain(
                _hop(
                    _source(address(broken), abi.encodeCall(MockAdapter.price, ()), 1 hours),
                    _stub(1990e18, block.timestamp, 1 hours)
                )
            )
        );

        assertEq(oracle.price(steth), 1990e18);
    }

    function test_price_treatsATimestamplessAnswerAsZero() public {
        MockAdapter short = new MockAdapter(2000e18, block.timestamp);
        IOracle.Sources[] memory hops =
            _chain(_hop(_source(address(short), abi.encodeCall(MockAdapter.shortPrice, ()), 1 hours)));

        assertEq(oracle.price(hops), 0);
    }

    function test_price_fallsToSecondaryWhenPrimaryReturnsExtraData() public {
        MockAdapter long = new MockAdapter(2000e18, block.timestamp);
        IOracle.Sources[] memory hops = _chain(
            _hop(
                _source(address(long), abi.encodeCall(MockAdapter.longPrice, ()), 1 hours),
                _stub(1990e18, block.timestamp, 1 hours)
            )
        );

        assertEq(oracle.price(hops), 1990e18);
    }

    // ── configuration ─────────────────────────────────────────────────────────

    function test_setSource_rejectsAChainThatCannotPrice() public {
        _set(steth, _chain(_hop(_stub(2000e18, block.timestamp, 1 hours))));
        IOracle.Sources[] memory hops = _chain(_hop(_stub(0, block.timestamp, 1 hours)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, steth));
        oracle.setSource(steth, hops);

        assertEq(oracle.price(steth), 2000e18, "the working chain was left alone");
    }

    function test_setSource_emitsIndexedAsset() public {
        IOracle.Sources[] memory hops = _chain(_hop(_stub(2000e18, block.timestamp, 1 hours)));

        vm.expectEmit(address(oracle));
        emit IOracle.SetSource(steth, hops);
        vm.prank(admin);
        oracle.setSource(steth, hops);
    }

    function test_setSource_canClearAChain() public {
        _set(steth, _chain(_hop(_stub(2000e18, block.timestamp, 1 hours))));

        IOracle.Sources[] memory empty = new IOracle.Sources[](0);
        vm.expectEmit(address(oracle));
        emit IOracle.SetSource(steth, empty);
        _set(steth, empty);

        assertEq(oracle.sources(steth).length, 0, "cleared");
        assertEq(oracle.price(steth), 0, "and no longer prices");
    }

    function test_setSource_replacingAChainDropsTheOldTail() public {
        IOracle.Sources memory usd = _hop(_stub(2000e18, block.timestamp, 1 hours));
        IOracle.Sources memory haircut = _hop(_stub(1.01e18, block.timestamp, 1 hours));
        _set(wsteth, _chain(_hop(_stub(1.05e18, block.timestamp, 1 days)), usd, haircut));
        assertEq(oracle.sources(wsteth).length, 3);

        _set(wsteth, _chain(_hop(_stub(1.05e18, block.timestamp, 1 days)), usd));

        assertEq(oracle.sources(wsteth).length, 2);
        assertEq(oracle.price(wsteth), 2100e18, "the haircut is gone");
    }

    function test_setSource_roundTripsPayloadsAndWindows() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        bytes memory payload = abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed));
        IOracle.Source memory primary = _source(chainlink, payload, 3 hours);
        IOracle.Source memory secondary = _stub(1990e18, block.timestamp, 1 days);
        _set(steth, _chain(_hop(primary, secondary)));

        IOracle.Sources[] memory read = oracle.sources(steth);

        assertEq(read.length, 1);
        assertEq(read[0].primary.adapter, chainlink);
        assertEq(keccak256(read[0].primary.payload), keccak256(payload));
        assertEq(read[0].primary.staleness, 3 hours);
        assertEq(read[0].secondary.adapter, secondary.adapter);
        assertEq(keccak256(read[0].secondary.payload), keccak256(secondary.payload));
        assertEq(read[0].secondary.staleness, 1 days);
    }

    function test_setSource_onlyAuthority() public {
        IOracle.Sources[] memory hops = _chain(_hop(_stub(2000e18, block.timestamp, 1 hours)));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        oracle.setSource(steth, hops);
    }

    function test_upgrade_authorized() public {
        Oracle newImpl = new Oracle();
        vm.prank(admin);
        UUPSUpgradeable(address(oracle)).upgradeToAndCall(address(newImpl), "");
        assertEq(oracle.authority(), address(accessManager));
    }

    function test_upgrade_unauthorized_reverts() public {
        Oracle newImpl = new Oracle();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        UUPSUpgradeable(address(oracle)).upgradeToAndCall(address(newImpl), "");
    }
}
