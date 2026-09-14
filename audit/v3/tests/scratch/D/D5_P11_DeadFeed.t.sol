// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// WS-D P11 (M-1 regression): one dead feed on a funded tranche reverts every price-walking
/// entry point of the market for as long as GOVERNOR does not setSource.
contract D5_P11_DeadFeed is CapDeployer {
    FloatingMarket market;
    address senior; // WETH-like (collateral)
    address mid; // X, the feed that dies
    address junior; // WETH-like (collateral)
    MockERC20 x;

    function setUp() public {
        _deployCap();
        x = _newCollateral("X", "X", 18, 1e18);
        address[] memory assets = new address[](3);
        assets[0] = address(collateral);
        assets[1] = address(x);
        assets[2] = address(collateral);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.5e27;
        weights[1] = 0.3e27;
        weights[2] = 0.2e27;
        (address m, address[] memory tranches) =
            _createMarket("D5", defaultMarketOwner, defaultBorrower, assets, weights);
        market = FloatingMarket(m);
        senior = tranches[0];
        mid = tranches[1];
        junior = tranches[2];
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, address(collateral), makeAddr("s"), 400e18);
        _fundTranche(mid, address(x), makeAddr("m"), 300e18);
        _fundTranche(junior, address(collateral), makeAddr("j"), 300e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        skip(1 hours); // premium to distribute on the next touch
    }

    function _killMidFeed() internal {
        // realistic outage: feed stops updating, staleness bound passes
        _setStaleness(address(x), 1 hours);
        skip(2 hours);
        assertEq(oracle.price(address(x)), 0, "oracle answers zero");
    }

    function test_everyPricePathReverts() public {
        _killMidFeed();
        bytes4 e = ITranche.InvalidPrice.selector;

        vm.expectRevert(e);
        market.totalCapital();
        vm.expectRevert(e);
        market.healthiness();
        vm.expectRevert(e);
        market.maxLiquidatable();
        vm.expectRevert(e);
        market.recoverableDebt();
        vm.expectRevert(e);
        market.unrecoverableDebt();
        vm.expectRevert(e);
        market.creditLimit();
        vm.expectRevert(e);
        market.availableCredit();
        // lockedValue for tranches senior to the dead one walks it
        vm.expectRevert(e);
        market.lockedValue(senior);
        vm.expectRevert(e);
        Tranche(senior).unlockedSupply();
        vm.expectRevert(e);
        Tranche(mid).unlockedSupply();
        // the tranche junior to the dead one never prices it: the call returns (it is fully
        // locked here, so the value is zero, but it does not revert)
        Tranche(junior).unlockedSupply();
        assertGt(Tranche(junior).totalCapital(), 0, "junior prices itself fine");

        vm.prank(defaultBorrower);
        vm.expectRevert(e);
        market.borrow(defaultBorrower, 1e18);

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(e);
        market.liquidate(defaultLiquidator, 100e18);

        vm.expectRevert(e);
        market.writeOff();

        // premium distribution prices every tranche with staked supply
        vm.expectRevert(e);
        market.chargePremium();
        vm.expectRevert(e);
        market.setMarketMultiplier(1.5e27);
    }

    /// FAILS on current code: a floating borrower cannot even repay during the outage, because
    /// repay() first charges premium and the distribution loop prices the dead tranche.
    function test_FAIL_borrowerCanRepayDuringOutage() public {
        _killMidFeed();
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0);
    }

    /// The premium keeps accruing on the index throughout; when the feed returns, the borrower
    /// has been charged for the whole outage and nobody could liquidate or write off meanwhile.
    function test_debtAccruesThroughOutageAndRecoveryNeedsGovernor() public {
        uint256 debtBefore = market.totalDebt();
        _killMidFeed();
        skip(7 days);
        uint256 debtDuring = market.totalDebt(); // view: index only, no price
        assertGt(debtDuring, debtBefore);
        // only GOVERNOR can bring the market back, by re-pointing the source
        _setStaleness(address(x), FEED_STALENESS);
        // _setStaleness calls setSource with the same (stale) feed: the dry-run must see a price
        // so first refresh the feed's timestamp as a feed operator would
        assertGt(market.healthiness(), 0);
        assertGt(market.totalCapital(), 0);
    }

    /// Both stale -> brick; stale primary + fresh secondary -> fine.
    function test_secondarySourceFallback() public {
        MockAggregator secondary = new MockAggregator(8, 1e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feeds[address(x)])),
            staleness: 1 hours
        });
        hops[0].secondary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(secondary)),
            staleness: 1 days
        });
        oracle.setSource(address(x), hops);
        skip(2 hours); // primary stale, secondary fresh
        assertEq(oracle.price(address(x)), 1e18);
        assertGt(market.healthiness(), 0);
        skip(1 days); // both stale
        assertEq(oracle.price(address(x)), 0);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
    }

    /// A zero answer (feed returning 0 / negative) is the same brick.
    function test_zeroAnswerBricks() public {
        feeds[address(x)].setAnswer(0);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
        feeds[address(x)].setAnswer(-1);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
    }

    /// A reverting adapter/feed is the same brick (staticcall failure -> 0).
    function test_revertingFeedBricks() public {
        vm.etch(address(feeds[address(x)]), hex"fe"); // INVALID opcode
        assertEq(oracle.price(address(x)), 0);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
    }

    /// A dead feed on an EMPTY tranche is harmless (no price consulted), and a debt-free
    /// dead tranche can still exit (zero lock never prices).
    function test_emptyOrDebtFreeDeadTrancheIsHarmless() public {
        _mintStable(defaultBorrower, 100e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0);
        _killMidFeed();
        assertEq(Tranche(mid).unlockedSupply(), Tranche(mid).totalSupply(), "debt-free: full exit");
        // but any price-walking market view still reverts while the tranche holds assets
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.totalCapital();
    }

    /// Fixed market: repay does not charge premium, so it works; borrow/extend/extendAdmin/
    /// liquidate/writeOff do not.
    function test_fixedMarket_repayWorksOthersDoNot() public {
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(x);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e27;
        weights[1] = 0.5e27;
        _assignOperatorIfNeeded();
        (address m, address[] memory tranches) = registry.createFixedMarket(
            assets, weights, "D5F", _operatorRoleOf(defaultMarketOwner), 30 days, 1 days, 1 days
        );
        vm.prank(defaultMarketOwner);
        IBaseMarket(m).setBorrowerRole(_operatorRoleOf(defaultBorrower));
        FixedMarket fm = FixedMarket(m);
        fm.setLtv(0.5e27);
        fm.setFixedCreditLimit(1_000_000e18);
        fm.setUnderwriterRate(0.2e27);
        _fundTranche(tranches[0], address(collateral), makeAddr("fs"), 500e18);
        _fundTranche(tranches[1], address(x), makeAddr("fj"), 500e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = fm.borrow(defaultBorrower, 300e18, 10 days);

        _killMidFeed();
        bytes4 e = ITranche.InvalidPrice.selector;
        vm.prank(defaultBorrower);
        vm.expectRevert(e);
        fm.borrowMore(id, defaultBorrower, 1e18);
        vm.prank(defaultBorrower);
        vm.expectRevert(e);
        fm.extend(id, 1 days);
        skip(20 days);
        vm.expectRevert(e);
        fm.extendAdmin(id, 1 days);
        vm.prank(defaultLiquidator);
        vm.expectRevert(e);
        fm.liquidate(id, defaultLiquidator, 1e18);
        vm.expectRevert(e);
        fm.writeOff(id);
        // repay still works
        _mintStable(defaultBorrower, 400e18);
        vm.prank(defaultBorrower);
        fm.repay(id, type(uint256).max);
        assertEq(fm.debt(id), 0);
    }

    function _assignOperatorIfNeeded() internal {
        if (_operatorRoleOf(defaultMarketOwner) == 0) _assignOperator(defaultMarketOwner);
    }
}
