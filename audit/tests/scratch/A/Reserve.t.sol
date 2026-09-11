// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice H1 / I1 / I3 under the real protocol: minted yield, borrow/repay, write-off, deposits and
/// redemptions. Checks the reserve identity `balance == unlockedSupply` and measures the
/// creditBackedSupply vs totalDebt drift from premium rounding.
contract ReserveTest is CapDeployer, ERC1155Holder {
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
        assertEq(r, u, "reserve != unlockedSupply");
        assertGe(stablecoin.totalSupply(), stablecoin.creditBackedSupply() + stablecoin.badDebt(), "I2 broken");
    }

    /// I1 holds with equality through borrow, yield accrual, deposit, redeem: minted yield never
    /// touches the reserve nor unlockedSupply. The redeemable fraction of supply decays as yield mints.
    function test_yieldMintsDoNotMoveReserveOrUnlocked() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, lp, 10_000e18);
        _depositStable(depositor, 1_000e18);
        _identity();

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        _identity();
        uint256 unlockedBefore = stablecoin.unlockedSupply();
        uint256 supplyBefore = stablecoin.totalSupply();

        for (uint256 i; i < 365; ++i) {
            vm.warp(block.timestamp + 1 days);
            b.market.chargePremium();
        }
        _identity();
        assertEq(stablecoin.unlockedSupply(), unlockedBefore, "yield changed unlocked");
        emit log_named_uint("supply before yield", supplyBefore);
        emit log_named_uint("supply after 1y    ", stablecoin.totalSupply());
        emit log_named_uint("unlocked (reserve) ", stablecoin.unlockedSupply());
        emit log_named_uint("credit backed      ", stablecoin.creditBackedSupply());
        emit log_named_uint("market totalDebt   ", b.market.totalDebt());
        emit log_named_uint("utilization (ray)  ", stablecoin.utilizationRate());
        // I3 drift in wei
        if (stablecoin.creditBackedSupply() >= b.market.totalDebt()) {
            emit log_named_uint("credit - debt (wei)", stablecoin.creditBackedSupply() - b.market.totalDebt());
        } else {
            emit log_named_uint("DEBT - credit (wei)", b.market.totalDebt() - stablecoin.creditBackedSupply());
        }

        // redeem all of the reserve, then the lender's yield cannot exit until someone deposits
        uint256 maxOut = stablecoin.maxRedeem(depositor);
        vm.prank(depositor);
        stablecoin.redeem(maxOut, depositor, depositor);
        _identity();
        assertEq(stablecoin.unlockedSupply(), 0, "reserve drained");
        assertEq(stablecoin.maxRedeem(capConfig.stablecoinYield), 0, "yield holder cannot exit");
    }

    /// I3 drift: after many accruals at random intervals, does totalDebt ever exceed
    /// creditBackedSupply (which would make the final wei of repayment / write-off underflow)?
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
        }
        uint256 debt = b.market.totalDebt();
        uint256 credit = stablecoin.creditBackedSupply();
        if (debt > credit) emit log_named_uint("DEBT exceeds credit by", debt - credit);
        assertLe(debt, credit, "I3: totalDebt > creditBackedSupply");

        // full repay must be possible: give the borrower whatever cUSD is needed via a par deposit
        uint256 held = stablecoin.balanceOf(defaultBorrower);
        if (debt > held) _depositStable(defaultBorrower, debt - held);
        vm.prank(defaultBorrower);
        b.market.repay(type(uint256).max);
        assertEq(b.market.totalDebt(), 0, "debt not cleared");
        _identity();
    }

    /// Write-off + redemption + cover path under the real market: reserve identity and I2/I4.
    function test_writeOffThenRedeemThenCoverReconciles() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, lp, 1_000e18);
        _depositStable(depositor, 1_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        _identity();

        // collateral collapses so most of the debt is unrecoverable
        oracle.setPrice(address(collateral), 0.1e18);
        uint256 unrecoverable = b.market.unrecoverableDebt();
        assertGt(unrecoverable, 0);
        uint256 written = b.market.writeOff();
        assertEq(stablecoin.badDebt(), written);
        _identity();
        emit log_named_uint("written off", written);
        emit log_named_uint("totalSupply", stablecoin.totalSupply());
        emit log_named_uint("totalAssets", stablecoin.totalAssets());
        emit log_named_uint("unlocked   ", stablecoin.unlockedSupply());

        // depositor exits half
        uint256 half = stablecoin.maxRedeem(depositor) / 2;
        uint256 pv = stablecoin.previewRedeem(half);
        vm.prank(depositor);
        uint256 paid = stablecoin.redeem(half, depositor, depositor);
        assertEq(paid, pv);
        assertLt(paid, half, "haircut applied");
        _identity();
        emit log_named_uint("paid for half", paid);
        emit log_named_uint("badDebt after", stablecoin.badDebt());

        // governor covers from a par mint
        uint256 bad = stablecoin.badDebt();
        _depositStable(address(this), bad);
        stablecoin.coverBadDebt(bad);
        assertEq(stablecoin.badDebt(), 0);
        _identity();
        // now the rest exits at par
        uint256 rest = stablecoin.maxRedeem(depositor);
        vm.prank(depositor);
        uint256 paid2 = stablecoin.redeem(rest, depositor, depositor);
        assertEq(paid2, rest, "at par after cover");
        _identity();
    }

    /// Fixed market: same I3 check across borrow + extension rounds
    function testFuzz_fixedDebtNeverExceedsCredit(uint256 seed, uint8 rounds, uint256 principal) public {
        rounds = uint8(bound(rounds, 1, 10));
        principal = bound(principal, 1e18, 2_000e18);
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        FixedMarket market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, lp, 10_000e18);
        _depositStable(depositor, 1_000e18);

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, principal, 10 days);
        for (uint256 i; i < rounds; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + (seed % 12 days));
            if (block.timestamp >= market.expiry(id)) {
                vm.warp(market.expiry(id) + capConfig.defaultGrace);
                market.extendAdmin(id, 5 days);
            } else {
                market.extend(id, 1 days);
            }
            _identity();
        }
        assertLe(market.totalDebt(), stablecoin.creditBackedSupply(), "I3: fixed totalDebt > credit");
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "I3: fixed debt != credit");
    }

    /// Deterministic consequence of the I3 drift: with a single market, once totalDebt has drifted
    /// above creditBackedSupply, a full repayment and a full write-off both revert on the
    /// `creditBackedSupply -= amount` underflow, and partial repayment preserves the gap, so the
    /// loan can never be cleared without another market first borrowing to add slack.
    function test_driftBricksFullRepayAndWriteOff() public {
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
        assertGt(debt, credit, "precondition: drift in the harmful direction");
        uint256 gap = debt - credit;
        emit log_named_uint("gap (wei)          ", gap);

        // borrower acquires enough cUSD at par to repay everything
        _depositStable(defaultBorrower, debt);

        // (a) full repay reverts: burnCreditBacked underflows
        vm.prank(defaultBorrower);
        vm.expectRevert();
        b.market.repay(type(uint256).max);

        // (b) partial repay works but the gap is preserved exactly
        vm.prank(defaultBorrower);
        b.market.repay(debt - 1e18);
        assertEq(b.market.totalDebt() - stablecoin.creditBackedSupply(), gap, "gap invariant under repay");

        // (c) the remainder can never be cleared
        vm.prank(defaultBorrower);
        vm.expectRevert();
        b.market.repay(type(uint256).max);

        // (d) strip the collateral through liquidation at a crashed price (liquidation preserves the
        // gap exactly as repay does), leaving a remainder that is 100% unrecoverable, then write-off
        // of that remainder reverts too
        oracle.setPrice(address(collateral), 1e6);
        _depositStable(defaultLiquidator, 1e18);
        for (uint256 i; i < 5 && b.market.maxLiquidatable() > 1000; ++i) {
            vm.prank(defaultLiquidator);
            b.market.liquidate(defaultLiquidator, type(uint256).max);
        }
        emit log_named_uint("capital left (wei) ", b.market.totalCapital());
        assertLt(b.market.recoverableDebt(), gap, "recoverable below the gap");
        assertEq(b.market.totalDebt() - stablecoin.creditBackedSupply(), gap, "gap invariant under liquidation");
        assertGt(b.market.unrecoverableDebt(), stablecoin.creditBackedSupply(), "write-off amount exceeds credit");
        emit log_named_uint("remaining debt     ", b.market.totalDebt());
        vm.expectRevert();
        b.market.writeOff();

        // this is the state the existing repo test claims cannot happen
        assertLe(b.market.totalDebt(), stablecoin.creditBackedSupply(), "I3 (repo test assertion)");
    }
}
