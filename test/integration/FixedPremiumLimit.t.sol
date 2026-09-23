// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

contract FixedPremiumLimitTest is CapDeployer {
    FixedMarket internal market;

    function setUp() public {
        _deployCap();
        (address deployed, address senior,) = _createFixedMarket("Premium limit");
        market = FixedMarket(deployed);
        market.setUnderwriterRate(0.2e27);
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        _setMaxCapital(market, 10_000e18);
        _fundTranche(senior, makeAddr("senior"), 10_000e18);
        _depositStable(makeAddr("reserve holder"), 10_000e18);
        vm.warp(block.timestamp + 20 * irm.averagingPeriod());
        irm.updateLiquidityRate();
    }

    function testFuzz_exactPremiumLimitAndOneWeiBelow(uint96 rawPrincipal, uint32 rawTerm, bool addOn, bool maximumDraw)
        public
    {
        uint256 term = bound(rawTerm, 1 days, 30 days);
        if (addOn) _draw(false, 100e18, term, type(uint256).max);
        uint256 principal = maximumDraw ? market.availableCredit(term) : bound(rawPrincipal, 1e18, 3_000e18);
        uint256 requested = maximumDraw ? type(uint256).max : principal;
        uint256 premium = _quote(principal, term);
        assertGt(premium, 0);

        _assertRejected(addOn, requested, term, premium, premium - 1);

        uint256 debtBefore = market.totalDebt();
        uint256 balanceBefore = stablecoin.balanceOf(defaultBorrower);
        uint256 actual = _draw(addOn, requested, term, premium);
        assertEq(actual, principal);
        assertEq(market.totalDebt() - debtBefore, actual + premium);
        assertEq(stablecoin.balanceOf(defaultBorrower) - balanceBefore, actual);
    }

    function testFuzz_priorBorrowCannotExceedQuotedPremium(bool addOn) public {
        uint256 term = 30 days;
        if (addOn) _draw(false, 100e18, term, type(uint256).max);
        uint256 quoted = _quote(1_000e18, term);

        // Another draw lands between the user's quote and their transaction.
        _draw(false, 1_000e18, term, type(uint256).max);
        uint256 repriced = _quote(1_000e18, term);
        assertGt(repriced, quoted);
        _assertRejected(addOn, 1_000e18, term, repriced, quoted);
    }

    function testFuzz_underwriterRateIncreaseCannotExceedQuotedPremium(bool addOn) public {
        uint256 term = 30 days;
        if (addOn) _draw(false, 100e18, term, type(uint256).max);
        uint256 quoted = _quote(1_000e18, term);
        market.setUnderwriterRate(0.4e27);
        uint256 repriced = _quote(1_000e18, term);
        assertGt(repriced, quoted);
        _assertRejected(addOn, 1_000e18, term, repriced, quoted);
    }

    function test_zeroLimitAllowsOnlyZeroPremium() public {
        _assertRejected(false, 1_000e18, 30 days, _quote(1_000e18, 30 days), 0);
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: 0, slope0: 0, slope1: 0, kink: 0.8e27 }));
        market.setUnderwriterRate(0);
        assertEq(_quote(1_000e18, 30 days), 0);
        assertEq(_draw(false, 1_000e18, 30 days, 0), 1_000e18);
        assertEq(_draw(true, 100e18, 30 days, 0), 100e18);
        assertEq(market.debt(0), 1_100e18);
    }

    function test_newSelectorsRequireBorrowerPermission() public {
        _draw(false, 100e18, 30 days, type(uint256).max);
        address stranger = makeAddr("stranger");
        bytes memory unauthorized = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger);
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        market.borrow(stranger, 100e18, 30 days, type(uint256).max);
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        market.borrowMore(0, stranger, 100e18, type(uint256).max);
    }

    function _draw(bool addOn, uint256 principal, uint256 term, uint256 maxPremium) internal returns (uint256 actual) {
        vm.prank(defaultBorrower);
        if (addOn) actual = market.borrowMore(0, defaultBorrower, principal, maxPremium);
        else (, actual) = market.borrow(defaultBorrower, principal, term, maxPremium);
    }

    function _quote(uint256 principal, uint256 term) internal view returns (uint256 premium) {
        (uint256 liquidity, uint256 underwriting) = market.premiumForBorrow(principal, term);
        premium = liquidity + underwriting;
    }

    function _assertRejected(bool addOn, uint256 principal, uint256 term, uint256 premium, uint256 limit) internal {
        uint256 id = addOn ? 0 : market.loanCount();
        bytes32 beforeState = _state(id);
        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.PremiumExceedsLimit.selector, premium, limit));
        _draw(addOn, principal, term, limit);
        assertEq(_state(id), beforeState, "rejected draw changes neither the loan nor cUSD accounting");
    }

    function _state(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                market.loanCount(),
                market.expiry(id),
                market.debt(id),
                market.totalDebt(),
                stablecoin.totalSupply(),
                stablecoin.creditBackedSupply(),
                stablecoin.balanceOf(defaultBorrower)
            )
        );
    }
}
