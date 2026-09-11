// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// @notice Round-2 port of audit/tests/scratch/A/DriftStats.t.sol (L-1). Logs the sign and size of
/// the creditBackedSupply vs totalDebt drift from FloatingMarket._premium's two-part rounding.
contract L1_DriftStatsTest is CapDeployer {
    address internal lp = makeAddr("lp");
    address internal depositor = makeAddr("depositor");

    function setUp() public {
        capConfig = _defaultCapConfig();
        capConfig.applyLiquiditySlopes = true;
        _deployCapWithConfig(capConfig);
    }

    function _run(string memory label, uint256 underwriterRate, uint256 interval, uint256 n, uint256 principal)
        internal
    {
        uint256 snap = vm.snapshotState();
        MarketBundle memory b = _createReadyMarket(label);
        b.market.setUnderwriterRate(underwriterRate);
        _fundTranche(b.tranche0Addr, lp, 100_000e18);
        _depositStable(depositor, 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, principal);

        uint256 worst;
        uint256 debtAbove;
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + interval);
            b.market.chargePremium();
            uint256 d = b.market.totalDebt();
            uint256 c = stablecoin.creditBackedSupply();
            if (d > c) {
                debtAbove++;
                if (d - c > worst) worst = d - c;
            }
        }
        uint256 d = b.market.totalDebt();
        uint256 c = stablecoin.creditBackedSupply();
        emit log_string(label);
        emit log_named_uint("  accruals            ", n);
        emit log_named_uint("  final debt          ", d);
        emit log_named_uint("  final credit        ", c);
        if (d >= c) emit log_named_uint("  final DEBT - credit ", d - c);
        else emit log_named_uint("  final credit - debt ", c - d);
        emit log_named_uint("  worst DEBT - credit ", worst);
        emit log_named_uint("  accruals w/ debt>cr ", debtAbove);
        vm.revertToState(snap);
    }

    function test_driftStats() public {
        _run("daily x365, uw 20%, principal 400", 0.2e27, 1 days, 365, 400e18);
        _run("hourly x720, uw 20%, principal 400", 0.2e27, 1 hours, 720, 400e18);
        _run("12s x2000, uw 20%, principal 400", 0.2e27, 12, 2000, 400e18);
        _run("daily x365, uw 0%, principal 400", 0, 1 days, 365, 400e18);
        _run("daily x365, uw 20%, principal 49999", 0.2e27, 1 days, 365, 49_999e18);
        _run("daily x365, uw 20%, principal 1", 0.2e27, 1 days, 365, 1e18);
        _run("daily x1095, uw 20%, principal 400", 0.2e27, 1 days, 1095, 400e18);
    }
}
