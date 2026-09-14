// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// Round-3 port of round-1 M-1 (C3 / R1_M1_OracleBricksLiquidation). HEAD narrows the brick:
/// `Tranche.totalCapital` skips the oracle when `totalAssets() == 0` (Tranche.sol:177-181) and
/// `unlockedSupply` skips it when `lockedValue == 0` (:163-174). A FUNDED tranche with a dead feed
/// still reverts `InvalidPrice` (:216-219) inside every market aggregate (BaseMarket.sol:292-297).
contract R1_M1_OracleBricksLiquidation is CapDeployer {
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    MockERC20 tokenB;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        tokenB = _newCollateral("Token B", "B", 18, 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(tokenB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.95e27;
        weights[1] = 0.05e27;
        (address m, address[] memory ts) = _createMarket("Multi", defaultMarketOwner, defaultBorrower, assets, weights);
        market = FloatingMarket(m);
        senior = Tranche(ts[0]);
        junior = Tranche(ts[1]);
        _setMarketSlopes(m);

        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), address(tokenB), bob, 1e18); // 0.1% of capital
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
    }

    function _makeStale() internal {
        // tokenB's feed goes stale; the senior collateral crashes 70% in the same window
        _setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        _setPrice(address(collateral), 0.3e18); // refreshes only the collateral feed's updatedAt
    }

    function test_oneStaleFeedBricksLiquidationAndRedemption() public {
        _makeStale();

        _probe(address(market), "market.healthiness", abi.encodeCall(market.healthiness, ()));
        _probe(address(market), "market.maxLiquidatable", abi.encodeCall(market.maxLiquidatable, ()));
        _probe(address(market), "market.unrecoverableDebt", abi.encodeCall(market.unrecoverableDebt, ()));
        _probe(address(market), "market.availableCredit", abi.encodeCall(market.availableCredit, ()));
        _probe(address(market), "market.writeOff (GUARDIAN)", abi.encodeCall(market.writeOff, ()));
        _probe(address(senior), "senior.totalCapital (own feed fine)", abi.encodeCall(senior.totalCapital, ()));
        _probe(address(senior), "senior.unlockedSupply", abi.encodeCall(senior.unlockedSupply, ()));
        _probe(address(senior), "senior.maxRedeem(alice)", abi.encodeCall(senior.maxRedeem, (alice)));
        _probe(address(senior), "senior.maxInstantRedeem(alice)", abi.encodeCall(senior.maxInstantRedeem, (alice)));
        _probe(address(junior), "junior.unlockedSupply", abi.encodeCall(junior.unlockedSupply, ()));
        _probe(address(junior), "junior.totalCapital (dead feed)", abi.encodeCall(junior.totalCapital, ()));
        // repay still works: the borrower can leave, the underwriters cannot
        _mintStable(defaultBorrower, 1e18);
        vm.prank(defaultBorrower);
        market.repay(1e18);
        emit log_named_string("market.repay", "ok");
        _mintStable(makeAddr("anyone"), 0);
        vm.prank(makeAddr("anyone"));
        market.chargePremium();
        emit log_named_string("market.chargePremium (anyone)", "ok");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(defaultLiquidator, 100e18);
        assertGt(repaid, 0, "liquidation of the crashed senior collateral must not depend on the junior feed");
    }

    /// Failure mode unchanged from round 2: Oracle.price() returns 0 for a stale asset; Tranche.getPrice()
    /// reverts InvalidPrice(), which every market aggregate inherits.
    function test_staleFeed_oracleReturnsZero_trancheRevertsInvalidPrice() public {
        _makeStale();
        assertEq(oracle.price(address(tokenB)), 0, "stale feed answers 0");
        assertEq(oracle.price(address(collateral)), 0.3e18, "fresh feed still priced");

        vm.expectRevert(ITranche.InvalidPrice.selector);
        junior.totalCapital();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.maxLiquidatable();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        senior.maxRedeem(alice);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        senior.unlockedSupply();
    }

    /// The narrowing on HEAD, characterised: an EMPTY tranche with a dead feed no longer bricks the
    /// market (totalCapital short-circuits at zero assets), and a debt-free market lets the
    /// dead-feed tranche exit (unlockedSupply short-circuits at zero lock).
    function test_narrowing_emptyDeadFeedTrancheDoesNotBrick() public {
        // bob leaves the junior while it is unlocked (repay first), then the debt comes back
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        uint256 bobShares = junior.balanceOf(bob);
        vm.prank(bob);
        junior.instantRedeem(bobShares, bob, bob);
        assertGt(junior.totalAssets(), 0, "dead-share dust remains");
        emit log_named_uint("junior assets after exit (wei)", junior.totalAssets());
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        _makeStale();
        // dust is not zero, so the short-circuit does not apply: still bricked with 1000 wei of tokenB
        (bool ok,) = address(market).staticcall(abi.encodeCall(market.healthiness, ()));
        emit log_named_string("healthiness with 1000 wei of dead-feed junior", ok ? "ok" : "REVERT");
        assertFalse(ok, "dead-share dust keeps the brick alive");
    }

    function test_narrowing_debtFreeTrancheExitsAfterFeedDies() public {
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0);
        _makeStale();
        uint256 bobShares = junior.balanceOf(bob);
        assertEq(junior.unlockedSupply(), junior.totalSupply(), "zero lock never consults the oracle");
        vm.prank(bob);
        uint256 out = junior.instantRedeem(bobShares, bob, bob);
        assertEq(out, bobShares, "debt-free exit works with a dead feed");
    }

    function _probe(address target, string memory label, bytes memory data) internal {
        (bool ok,) = target.call(data);
        emit log_named_string(label, ok ? "ok" : "REVERT");
    }
}
