// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-1 (A/Reserve.t.sol -> R2 market/L1_Reserve). Round 1/2:
/// `FloatingMarket._premium` half-up rounding walked `totalDebt` above `creditBackedSupply`
/// (17 wei/yr), and full `repay(max)` / `writeOff()` then underflowed `creditBackedSupply -=`.
/// HEAD (a843c1d): `_premium` is the difference of three valuations that use the same product as
/// `totalDebt()` (FloatingMarket.sol:215-227) and `_borrowWithin`/`_repayWithin` mint/burn exactly
/// the representable change (:148-167), so Σ minted == Δ totalDebt to the wei.
contract R1_L1_PremiumDrift is CapDeployer {
    address internal depositor = makeAddr("depositor");
    address internal lp = makeAddr("lp");

    function setUp() public {
        capConfig = _defaultCapConfig();
        capConfig.applyLiquiditySlopes = true;
        _deployCapWithConfig(capConfig);
    }

    function _identity() internal view {
        uint256 r = cusdUnderlying.balanceOf(address(stablecoin));
        uint256 u = stablecoin.unlockedSupply();
        assertGe(r, u, "I1 broken: reserve below unlockedSupply");
        assertGe(stablecoin.totalSupply(), stablecoin.creditBackedSupply() + stablecoin.badDebt(), "I2 broken");
    }

    function testFuzz_debtNeverExceedsCredit(uint256 seed, uint8 rounds, uint256 principal) public {
        rounds = uint8(bound(rounds, 1, 60));
        principal = bound(principal, 1e18, 4_000e18);
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, lp, 10_000e18);
        _depositStable(depositor, 1_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, principal);

        for (uint256 i; i < rounds; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + (seed % 30 days));
            b.market.chargePremium();
            _identity();
            assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "I3 exact after each charge");
        }
        uint256 debt = b.market.totalDebt();
        uint256 held = stablecoin.balanceOf(defaultBorrower);
        if (debt > held) _depositStable(defaultBorrower, debt - held);
        vm.prank(defaultBorrower);
        b.market.repay(type(uint256).max);
        assertEq(b.market.totalDebt(), 0, "debt not cleared");
        assertEq(stablecoin.creditBackedSupply(), 0, "credit not cleared");
        _identity();
    }

    /// 365 daily accruals (the round-1 deterministic case: gap 17 wei, full repay reverted)
    function test_dailyAccrualsOneYear_fullRepayAndWriteOffSucceed() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, lp, 10_000e18);
        _depositStable(depositor, 1_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        for (uint256 i; i < 365; ++i) {
            vm.warp(block.timestamp + 1 days);
            b.market.chargePremium();
        }
        uint256 debt = b.market.totalDebt();
        uint256 credit = stablecoin.creditBackedSupply();
        emit log_named_uint("totalDebt          ", debt);
        emit log_named_uint("creditBackedSupply ", credit);
        emit log_named_int("gap (wei)          ", int256(debt) - int256(credit));
        assertEq(debt, credit, "I3: totalDebt == creditBackedSupply");

        // (a) full repay must not revert
        _depositStable(defaultBorrower, debt);
        vm.prank(defaultBorrower);
        b.market.repay(type(uint256).max);
        assertEq(b.market.totalDebt(), 0);
        assertEq(stablecoin.creditBackedSupply(), 0);

        // (b) the write-off path on the last-standing market: strip collateral, write off the rest
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        for (uint256 i; i < 100; ++i) {
            vm.warp(block.timestamp + 1 days);
            b.market.chargePremium();
        }
        _setPrice(address(collateral), 1e10);
        _depositStable(defaultLiquidator, 1e18);
        for (uint256 i; i < 5 && b.market.maxLiquidatable() > 1000; ++i) {
            vm.prank(defaultLiquidator);
            b.market.liquidate(defaultLiquidator, type(uint256).max);
        }
        emit log_named_uint("remaining debt     ", b.market.totalDebt());
        emit log_named_uint("unrecoverableDebt  ", b.market.unrecoverableDebt());
        emit log_named_uint("creditBackedSupply ", stablecoin.creditBackedSupply());
        assertLe(b.market.unrecoverableDebt(), stablecoin.creditBackedSupply(), "write-off amount within credit");
        b.market.writeOff();
        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "I3 after write-off");
    }
}
