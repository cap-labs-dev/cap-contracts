// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// P8: a borrower who opts in on cUSD is paid a share of the liquidity premium it is itself paying.
contract P8_BorrowerOptIn is CapDeployer {
    address lender = makeAddr("lender");
    address uwDepositor = makeAddr("uw");
    MarketBundle b;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true; // base 5%, slope0 5%, slope1 10%, kink 80%
        cfg.defaultFixedCreditLimit = 10_000_000e18;
        _deployCapWithConfig(cfg);
        b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, uwDepositor, 4_000_000e18);
        _depositStable(lender, 1_000_000e18); // reserve-backed cUSD, the honest lender
        vm.prank(lender);
        stablecoin.optIn();
    }

    function test_P8_borrowerCapturesLiquidityPremium() public {
        vm.startPrank(defaultBorrower);
        uint256 D = b.market.borrow(defaultBorrower, 1_000_000e18);
        stablecoin.optIn(); // borrower stakes the cUSD it just minted
        vm.stopPrank();

        uint256 util = stablecoin.utilizationRate();
        uint256 liqRate = irm.liquidityRate();
        emit log_named_decimal_uint("utilization (ray)", util, 27);
        emit log_named_decimal_uint("liquidity rate /yr (ray)", liqRate, 27);

        vm.warp(block.timestamp + 365 days);
        b.market.chargePremium();
        (uint256 liqPrem, uint256 uwPrem) = (0, 0);
        uint256 debtAfter = b.market.totalDebt();
        emit log_named_decimal_uint("debt after 1y", debtAfter, 18);

        vm.warp(block.timestamp + 7 days); // let the pot vest (12h constant)
        vm.prank(defaultBorrower);
        uint256 borrowerGot = stablecoin.claim(defaultBorrower);
        vm.prank(lender);
        uint256 lenderGot = stablecoin.claim(lender);
        emit log_named_decimal_uint("liquidity premium claimed by BORROWER", borrowerGot, 18);
        emit log_named_decimal_uint("liquidity premium claimed by LENDER", lenderGot, 18);
        uint256 paid = debtAfter - D;
        emit log_named_decimal_uint("total premium borrower owes (liq+uw)", paid, 18);
        emit log_named_decimal_uint("borrower effective cost after capture", paid - borrowerGot, 18);
        // the borrower recovers a material share of what it pays
        assertGt(borrowerGot, lenderGot / 2, "borrower captured at least a third of the pot");
        liqPrem;
        uwPrem;
    }
}
