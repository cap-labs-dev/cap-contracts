// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D / I8. setLt may drop lt below ltv (documented). FixedMarket._borrow asserts health
/// afterwards; FloatingMarket.borrow does not, so a borrower can draw straight into a liquidatable
/// position and the tranches pay the liquidation bonus on a position that never should have opened.
contract D4_FloatingBorrowUnhealthy is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_floatingBorrowLandsLiquidatable_whenLtBelowLtv() public {
        MarketBundle memory b = _createReadyMarket("F");
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        // guardian drops lt below the standing ltv (0.5): permitted by setLt
        b.market.setLt(0.4e27);
        assertGt(b.market.variableCreditLimit(), b.market.debtLiquidationThreshold(), "I8 broken by setLt");

        vm.prank(defaultBorrower);
        uint256 drawn = b.market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("drawn      ", drawn);
        emit log_named_uint("healthiness", b.market.healthiness());
        emit log_named_uint("maxLiquidatable", b.market.maxLiquidatable());
        assertGe(b.market.healthiness(), 1e27, "a borrow must never leave the market liquidatable");
    }

    function test_fixedBorrowRefuses_forContrast() public {
        (address m, address t0,) = _createFixedMarket("X");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(0);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, makeAddr("uw"), 10_000e18);
        market.setLt(0.4e27);
        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.Unhealthy.selector);
        market.borrow(defaultBorrower, type(uint256).max, 30 days);
    }
}
