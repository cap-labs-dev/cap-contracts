// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Round-2 port of round-1 D9 (M-5). Assertions identical to
/// audit/tests/scratch/D/D9_PhantomLoanId.t.sol; only the import depth changed.
contract R1_M5_PhantomLoanId is CapDeployer {
    FixedMarket market;

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        irm.setTermMultiplierSlope(1e27);
        (address m, address t0,) = _createFixedMarket("X");
        market = FixedMarket(m);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, makeAddr("uw"), 10_000e18);
        _depositStable(makeAddr("saver"), 10_000e18);
    }

    function test_reTermViaPhantomId_paysMinimumTermForMaximumTerm() public {
        uint256 id = market.loanCount(); // 0, never borrowed
        assertEq(market.expiry(id), 0);

        (uint256 l30, uint256 u30) = market.premiumForBorrow(4_000e18, 30 days);
        emit log_named_uint("honest 30-day premium on 4000", l30 + u30);

        // 1. owner gives the unused id a 1-day expiry
        market.extend(id, 1 days);
        assertEq(market.expiry(id), block.timestamp + 1 days);
        assertEq(market.debt(id), 0);

        // 2. borrower draws 4_000 on it for the 1 remaining day
        vm.prank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, 4_000e18);
        uint256 paidForOneDay = market.debt(id) - 4_000e18;
        emit log_named_uint("premium paid (1 day)         ", paidForOneDay);

        // 3. next borrow reuses the id and overwrites expiry to now + 30 days
        vm.prank(defaultBorrower);
        (uint256 newId,) = market.borrow(defaultBorrower, 1e18, 30 days);
        assertEq(newId, id, "loanCount reused the phantom id");
        assertEq(market.expiry(id), block.timestamp + 30 days, "4_000 of debt now has 30 days");
        uint256 paidTotal = market.debt(id) - 4_001e18;
        emit log_named_uint("premium paid in total        ", paidTotal);
        emit log_named_uint("premium avoided              ", (l30 + u30) - paidTotal);

        vm.warp(block.timestamp + 29 days);
        vm.prank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, 1); // still live: proves the term is real
        assertGe(paidTotal, l30 + u30, "30 days of exposure must cost the 30-day premium");
    }
}
