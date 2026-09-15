// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// @notice Round-1 M-1 port of audit/tests/scratch/C/C3_OracleBricksLiquidation.t.sol. Every market
/// view sums Tranche.totalCapital() over all tranches; a stale feed on ANY tranche (here a 0.1%
/// junior tranche) must not brick liquidation of the crashed senior collateral.
contract R1_M1_OracleBricksLiquidation is CapDeployer {
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    MockERC20 tokenB;

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

        _fundTranche(address(senior), makeAddr("alice"), 1000e18);
        _fundTranche(address(junior), address(tokenB), makeAddr("bob"), 1e18); // 0.1% of capital
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
        _probe(address(senior), "senior.maxRedeem(alice)", abi.encodeCall(senior.maxRedeem, (makeAddr("alice"))));
        _probe(address(junior), "junior.unlockedSupply", abi.encodeCall(junior.unlockedSupply, ()));
        // repay still works: the borrower can leave, the underwriters cannot
        _mintStable(defaultBorrower, 1e18);
        vm.prank(defaultBorrower);
        market.repay(1e18);
        emit log_named_string("market.repay", "ok");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(defaultLiquidator, 100e18);
        assertGt(repaid, 0, "liquidation of the crashed senior collateral must not depend on the junior feed");
    }

    /// @dev Documents the changed failure mode: Oracle.price() returns 0 for a stale asset (no
    /// revert); Tranche.getPrice() then reverts InvalidPrice(), which every market view inherits.
    function test_staleFeed_oracleReturnsZero_trancheRevertsInvalidPrice() public {
        _makeStale();
        uint256 pB = oracle.price(address(tokenB));
        uint256 pA = oracle.price(address(collateral));
        emit log_named_uint("oracle.price(tokenB) (stale)", pB);
        emit log_named_uint("oracle.price(collateral)", pA);
        assertEq(pB, 0, "stale feed answers 0");
        assertEq(pA, 0.3e18, "fresh feed still priced");

        vm.expectRevert(ITranche.InvalidPrice.selector);
        junior.totalCapital();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.healthiness();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.maxLiquidatable();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        senior.maxRedeem(makeAddr("alice"));
    }

    function _probe(address target, string memory label, bytes memory data) internal {
        (bool ok,) = target.call(data);
        emit log_named_string(label, ok ? "ok" : "REVERT");
    }
}
