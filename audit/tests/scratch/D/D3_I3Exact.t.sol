// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IFloatingMarket } from "../../../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D / I3. The exact identity is `sum(market.totalDebt()) == stablecoin.creditBackedSupply()`
/// with NO badDebt term: recognizeBadDebt lowers creditBackedSupply and the market lowers totalDebt
/// by the same amount in the same call. The fixed market is exact integers. The floating market
/// reads debt through `scaledDebt.rayMul(index)` and every borrow / premium charge / reindex rounds
/// half-up on both sides, so the reading drifts a wei either way per operation. When it drifts
/// ABOVE creditBackedSupply the final full repayment underflows `creditBackedSupply -= amount` and
/// the last few wei of debt can never be cleared.
contract D3_I3Exact is CapDeployer {
    FloatingMarket market;
    address uw = makeAddr("uw");

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        MarketBundle memory b = _createReadyMarket("F");
        market = b.market;
        _fundTranche(b.tranche0Addr, uw, 1_000_000e18);
        market.setFixedCreditLimit(type(uint256).max);
        _depositStable(makeAddr("saver"), 100_000e18);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_I3_floatingDebtEqualsCreditBackedSupply(uint256 seed) public {
        // credit-backed supply minted outside the market (none here: liquidator funds via deposit)
        int256 worst;
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 5;
            if (op == 0 || op == 1) {
                uint256 avail = market.availableCredit();
                if (avail > 1e18) {
                    uint256 amt = 1e18 + (r >> 8) % (avail - 1e18);
                    vm.prank(defaultBorrower);
                    market.borrow(defaultBorrower, amt);
                }
            } else if (op == 2) {
                vm.warp(block.timestamp + 1 + (r >> 8) % 200 days);
                market.chargePremium();
            } else if (op == 3) {
                uint256 debt = market.totalDebt();
                if (debt > 0) {
                    uint256 amt = 1 + (r >> 8) % debt;
                    vm.prank(defaultBorrower);
                    try market.repay(amt) { } catch { }
                }
            } else {
                uint256 mult = 1e27 + (r >> 8) % 1e27;
                market.setMarketMultiplier(mult);
            }
            int256 gap = int256(stablecoin.creditBackedSupply()) - int256(market.totalDebt());
            if (gap < worst) worst = gap;
            if (gap > 0 && -gap < worst) { }
        }
        emit log_named_int("worst (creditBackedSupply - totalDebt)", worst);
        assertEq(stablecoin.creditBackedSupply(), market.totalDebt(), "I3 must hold exactly");
    }

    /// @dev Deterministic: grow the index, then borrow amounts chosen to round the reading up, and
    /// show the full repayment reverting on the creditBackedSupply underflow.
    function test_fullRepayRevertsWhenReadingExceedsCredit() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1_000e18);
        vm.warp(block.timestamp + 3650 days);
        market.chargePremium();
        emit log_named_uint("index", market.index());

        // find borrows whose scaled rounding pushes the reading above the mint
        uint256 pushes;
        for (uint256 a = 1e18; a < 1e18 + 4000 && pushes < 40; ++a) {
            uint256 before = market.totalDebt();
            vm.prank(defaultBorrower);
            market.borrow(defaultBorrower, a);
            if (market.totalDebt() - before > a) pushes++;
            if (market.totalDebt() > stablecoin.creditBackedSupply()) break;
        }
        emit log_named_uint("totalDebt         ", market.totalDebt());
        emit log_named_uint("creditBackedSupply", stablecoin.creditBackedSupply());
        emit log_named_string(
            "reading above credit", market.totalDebt() > stablecoin.creditBackedSupply() ? "yes" : "no"
        );

        // the concrete consequence: the borrower cannot clear the loan
        uint256 debt = market.totalDebt();
        _depositStable(defaultBorrower, debt); // borrower sources every wei at par
        vm.prank(defaultBorrower);
        try market.repay(type(uint256).max) {
            emit log_string("full repay succeeded");
        } catch (bytes memory reason) {
            emit log_named_bytes("full repay reverted with", reason);
        }
        // trying to pay all but one wei instead leaves scaled dust that can never be cleared either
        if (market.totalDebt() > 0) {
            vm.prank(defaultBorrower);
            try market.repay(debt - 1) { } catch { }
            emit log_named_uint("debt left after repay(debt - 1)", market.totalDebt());
            emit log_named_uint("creditBackedSupply left        ", stablecoin.creditBackedSupply());
            vm.prank(defaultBorrower);
            try market.repay(type(uint256).max) { }
            catch (bytes memory reason) {
                emit log_named_bytes("second full repay reverted with", reason);
            }
        }
        assertEq(market.totalDebt(), 0, "the loan must be clearable in full");
    }
}
