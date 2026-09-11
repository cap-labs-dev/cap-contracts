// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice Round-2 port of audit/tests/scratch/A/Reserve.t.sol (L-1). Assertions preserved in
/// meaning. API changes: oracle.setPrice -> _setPrice (8-dec feed: price must be a multiple of
/// 1e10, so the "crashed" price is 1e10 rather than 1e6); depositors opt in via _fundTranche.
contract L1_ReserveTest is CapDeployer, ERC1155Holder {
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

        uint256 held = stablecoin.balanceOf(defaultBorrower);
        if (debt > held) _depositStable(defaultBorrower, debt - held);
        vm.prank(defaultBorrower);
        b.market.repay(type(uint256).max);
        assertEq(b.market.totalDebt(), 0, "debt not cleared");
        _identity();
    }

    /// Deterministic consequence of the I3 drift: with a single market, once totalDebt has drifted
    /// above creditBackedSupply, a full repayment and a full write-off both revert on the
    /// `creditBackedSupply -= amount` underflow (Stablecoin.sol:97 burnCreditBacked,
    /// Stablecoin.sol:150 recognizeBadDebt), and partial repayment preserves the gap.
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

        // (d) strip the collateral through liquidation at a crashed price, leaving a remainder
        // that is 100% unrecoverable, then write-off of that remainder reverts too
        _setPrice(address(collateral), 1e10);
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
        emit log_named_uint("unrecoverableDebt  ", b.market.unrecoverableDebt());
        emit log_named_uint("creditBackedSupply ", stablecoin.creditBackedSupply());
        vm.expectRevert();
        b.market.writeOff();

        // this is the state the existing repo test claims cannot happen
        assertLe(b.market.totalDebt(), stablecoin.creditBackedSupply(), "I3 (repo test assertion)");
    }
}
