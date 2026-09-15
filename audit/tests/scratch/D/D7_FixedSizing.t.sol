// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D. Fixed premium sizing: does principal + premium always fit inside the limit,
/// including tiny limits where the half-up rounding in _premium is a whole wei?
contract D7_FixedSizing is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_debtNeverExceedsLimit(uint96 rawLimit, uint32 rawTerm, uint8 rawSlope, uint8 rawUw) public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({
                base: 0.05e27, slope0: 0.05e27, slope1: bound(rawSlope, 0, 30) * 0.1e27, kink: 0.8e27
            })
        );
        irm.setTermMultiplierSlope(2e27);
        (address m, address t0,) = _createFixedMarket("X");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(bound(rawUw, 0, 100) * 0.01e27);
        market.setLtv(capConfig.defaultLt - capConfig.defaultBuffer);
        _fundTranche(t0, makeAddr("uw"), 10_000e18);
        uint256 limit = bound(rawLimit, 1, 5_000e18);
        market.setFixedCreditLimit(limit);
        uint256 term = bound(rawTerm, capConfig.defaultMinimumTermLimit, capConfig.defaultMaximumTermLimit);

        uint256 credit = market.availableCredit(term);
        if (credit == 0) return;
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, term);
        assertLe(market.debt(id), limit, "debt fits the limit");
        assertGe(market.healthiness(), 1e27, "healthy");
    }

    /// @dev Arrears on a rolled loan are priced at termUtilization >= 1 ray, i.e. the CHEAPEST
    /// point of the term curve, no matter how short the requested new term is.
    function test_arrearsArePricedAtTheCheapestTermMultiplier() public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        irm.setTermMultiplierSlope(2e27); // 1-day term pays 1 + 2*(29/30) = 2.93x liquidity rate
        (address m, address t0,) = _createFixedMarket("X");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(0);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, makeAddr("uw"), 10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 1_000e18, 30 days);
        uint256 debt = market.debt(id);

        // A: extend a live loan by the minimum term one second before expiry
        uint256 snap = vm.snapshotState();
        vm.warp(market.expiry(id) - 1);
        market.extend(id, 1 days);
        uint256 liveExtCost = market.debt(id) - debt;
        vm.revertToState(snap);

        // B: let it expire 29 days, then roll by the minimum term: 30 days of exposure billed at
        // termUtilization = 30/30 -> multiplier 1x
        vm.warp(market.expiry(id) + 29 days);
        market.extend(id, 1 days);
        uint256 rolledCost = market.debt(id) - debt;
        emit log_named_uint("1-day live extension cost         ", liveExtCost);
        emit log_named_uint("29d arrears + 1 day rolled cost   ", rolledCost);
        emit log_named_uint("per-day cost live                 ", liveExtCost);
        emit log_named_uint("per-day cost rolled               ", rolledCost / 30);
    }
}
