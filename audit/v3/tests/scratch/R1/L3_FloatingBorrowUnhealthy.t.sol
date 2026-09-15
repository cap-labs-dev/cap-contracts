// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-3 (D4). `FloatingMarket.borrow` (FloatingMarket.sol:60-72) still has
/// no post-borrow health assertion, but HEAD sizes credit off `min(ltv, lt)`
/// (BaseMarket.variableCreditLimit, :315-322), so a GUARDIAN `setLt` below `ltv` cuts the limit
/// instead of letting a draw land liquidatable.
contract R1_L3_FloatingBorrowUnhealthy is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_floatingBorrowLandsLiquidatable_whenLtBelowLtv() public {
        MarketBundle memory b = _createReadyMarket("F");
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        b.market.setLt(0.4e27); // below the standing ltv (0.5): permitted by setLt
        emit log_named_uint("variableCreditLimit     ", b.market.variableCreditLimit());
        emit log_named_uint("debtLiquidationThreshold", b.market.debtLiquidationThreshold());
        assertLe(b.market.variableCreditLimit(), b.market.debtLiquidationThreshold(), "I8 holds");

        vm.prank(defaultBorrower);
        uint256 drawn = b.market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("drawn          ", drawn);
        emit log_named_uint("healthiness    ", b.market.healthiness());
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
        // sized off min(ltv, lt) = 0.4 the fixed draw fits exactly; health lands on 1.0 (allowed)
        vm.prank(defaultBorrower);
        (, uint256 principal) = market.borrow(defaultBorrower, type(uint256).max, 30 days);
        emit log_named_uint("fixed principal", principal);
        assertGe(market.healthiness(), 1e27);
    }
}
