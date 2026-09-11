// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";

/// WS-C: every market view sums Tranche.totalCapital() over all tranches, and every tranche
/// conversion divides by its own oracle price. One stale feed on ANY tranche therefore reverts
/// healthiness(), maxLiquidatable(), liquidate(), writeOff(), borrow(), setTranches() and the
/// senior tranche's own redemption (lockedValue walks the junior tranches) - even when the
/// tranche with the bad feed holds a rounding error of the collateral.
contract C3_OracleBricksLiquidation is CapDeployer {
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    MockERC20 tokenB;

    function setUp() public {
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

    function test_oneStaleFeedBricksLiquidationAndRedemption() public {
        // tokenB's feed goes stale; the senior collateral crashes 70% in the same window
        oracle.setStaleness(address(tokenB), 1 hours);
        vm.warp(block.timestamp + 2 hours);
        oracle.setPrice(address(collateral), 0.3e18); // senior capital 300, debt 400: deeply underwater

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

    function _probe(address target, string memory label, bytes memory data) internal {
        (bool ok,) = target.call(data);
        emit log_named_string(label, ok ? "ok" : "REVERT");
    }
}
