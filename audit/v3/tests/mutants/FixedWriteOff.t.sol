// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice Kills Gambit `FixedMarket#122`, which deletes the `_writeOff(amount)` call in
/// {FixedMarket-writeOff}. With it gone the loan and the market's aggregate debt still fall by the
/// shortfall, but {Stablecoin-recognizeBadDebtInCredit} is never called: credit-backed supply keeps
/// the written-off amount, no bad debt is recognised, cUSD holders never take the haircut, and the
/// market reports itself healthier by exactly the amount that is now unbacked (I3, I30, and the
/// single promise of the plan). The `amount == 0` and `amount > unrecoverableDebt()` guards go with
/// it. It survives the stock suite and `FixedPartial.t.sol` because every fixed write-off assertion
/// reads the market (`debt`, `totalDebt`, `unrecoverableDebt`) and never the stablecoin.
contract FixedWriteOffKillTest is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function _readyFixed(uint256 capital) internal returns (FixedMarket market) {
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t0, makeAddr("senior"), capital);
    }

    /// A fixed write-off must land on the stablecoin as recognised bad debt, and credit-backed
    /// supply must keep tracking the market's debt.
    function test_fixedWriteOffRecognisesTheLossOnTheStablecoin() public {
        FixedMarket market = _readyFixed(10_000e18);

        vm.startPrank(defaultBorrower);
        (uint256 a,) = market.borrow(defaultBorrower, 2_000e18, 30 days);
        market.borrow(defaultBorrower, 2_000e18, 30 days);
        vm.stopPrank();
        assertEq(stablecoin.creditBackedSupply(), market.totalDebt(), "credit equals debt before the crash");

        _setPrice(address(collateral), 0.35e18);
        uint256 shortfall = market.unrecoverableDebt();
        assertGt(shortfall, 0, "the market is short");
        uint256 creditBefore = stablecoin.creditBackedSupply();
        uint256 supplyBefore = stablecoin.totalSupply();

        uint256 written = market.writeOff(a);

        assertEq(written, shortfall, "the whole shortfall is written off");
        assertEq(stablecoin.badDebt(), written, "the stablecoin recognises the loss");
        assertEq(stablecoin.creditBackedSupply(), creditBefore - written, "credit-backed supply drops by it");
        assertEq(stablecoin.creditBackedSupply(), market.totalDebt(), "and still equals the market's debt (I3)");
        assertEq(stablecoin.totalSupply(), supplyBefore, "supply is unchanged: holders carry the haircut");
        assertEq(stablecoin.backing(), supplyBefore - written, "recognised backing falls by the write-off");
    }

    /// A write-off with nothing unrecoverable is refused rather than silently recorded as zero.
    function test_fixedWriteOffOnAHealthyLoanIsRefused() public {
        FixedMarket market = _readyFixed(10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 1_000e18, 30 days);
        assertEq(market.unrecoverableDebt(), 0);
        uint256 debtBefore = market.debt(id);

        vm.expectRevert(IBaseMarket.InvalidAmount.selector);
        market.writeOff(id);

        assertEq(market.debt(id), debtBefore);
        assertEq(stablecoin.badDebt(), 0);
    }
}
