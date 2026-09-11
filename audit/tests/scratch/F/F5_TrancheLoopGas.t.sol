// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { console } from "forge-std/Test.sol";

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-F / DoS. BaseMarket loops over `tranches` in totalCapital, lockedValue, _liquidate,
/// _chargePremium. Measures gas per tranche so the report can state the N at which liquidation
/// or a senior-tranche redemption exceeds a 30M block. Not a failing test.
contract F5_TrancheLoopGas is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function _measure(uint256 n) internal {
        uint256[] memory weights = new uint256[](n);
        uint256 each = 1e27 / n;
        for (uint256 i; i < n; ++i) {
            weights[i] = each;
        }
        weights[0] += 1e27 - each * n;

        (address m, address[] memory tranches) =
            _createMarket(string(abi.encodePacked("N", vm.toString(n))), defaultMarketOwner, defaultBorrower, weights);
        FloatingMarket market = FloatingMarket(m);
        market.setFixedCreditLimit(type(uint256).max);
        for (uint256 i; i < n; ++i) {
            _fundTranche(
                tranches[i], makeAddr(string(abi.encodePacked("lp", vm.toString(n), "-", vm.toString(i)))), 100e18
            );
        }
        uint256 debt = 50e18 * n;
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, debt);

        uint256 g0 = gasleft();
        Tranche(tranches[0]).unlockedSupply();
        uint256 gUnlocked = g0 - gasleft();

        g0 = gasleft();
        market.healthiness();
        uint256 gHealth = g0 - gasleft();

        oracle.setPrice(address(collateral), 0.5e18);
        _mintStable(defaultLiquidator, debt);
        vm.prank(defaultLiquidator);
        g0 = gasleft();
        market.liquidate(defaultLiquidator, debt / 4);
        uint256 gLiq = g0 - gasleft();
        oracle.setPrice(address(collateral), 1e18);

        console.log("N=%s  senior unlockedSupply gas=%s  healthiness gas=%s", n, gUnlocked, gHealth);
        console.log("N=%s  liquidate gas=%s", n, gLiq);
    }

    function test_F5_gasPerTranche() public {
        _measure(2);
        _measure(10);
        _measure(40);
    }
}
