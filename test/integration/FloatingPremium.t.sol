// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice More frequent underwriting realization changes the premium split; debt still reconciles exactly.
contract FloatingPremiumTest is CapDeployer {
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        (address m, address t,) = _createMarket("Premium allocation");
        market = FloatingMarket(m);
        _fundTranche(t, makeAddr("supplier"), 1_000e18);
        _indices(RAY, RAY);
    }

    function _indices(uint256 liquidity, uint256 underwriting) internal {
        vm.mockCall(address(irm), abi.encodeCall(IInterestRateModel.liquidityIndex, ()), abi.encode(liquidity));
        vm.mockCall(
            address(irm),
            abi.encodeCall(IInterestRateModel.underwriterIndex, (address(market))),
            abi.encode(underwriting)
        );
    }

    function _borrow(uint256 principal) internal {
        vm.prank(defaultBorrower);
        assertEq(market.borrow(defaultBorrower, principal), principal);
    }

    function _advance(uint256 liquidity, uint256 underwriting) internal returns (uint256 lp, uint256 uw) {
        vm.warp(block.timestamp + 1);
        _indices(liquidity, underwriting);
        return market.premium();
    }

    function test_singleSettlementUsesOldLiquidityIndexForUnderwriting() public {
        _borrow(100e18);
        (uint256 liquidity, uint256 underwriting) = _advance(1.2e27, 1.2e27);
        assertEq(underwriting, 20e18);
        assertEq(liquidity, 24e18);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply(), 144e18);
    }

    function test_frequentSettlementChangesAllocationButNotTotalPremium() public {
        _borrow(100e18);
        (uint256 l1, uint256 u1) = _advance(1.1e27, 1.1e27);
        market.chargePremium();
        (uint256 l2, uint256 u2) = _advance(1.2e27, 1.2e27);
        assertEq(u1 + u2, 21e18);
        assertEq(l1 + l2, 23e18);
        assertEq(l1 + l2 + u1 + u2, 44e18);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply(), 144e18);
    }

    function test_divergentIndexesAndDustDoNotUnderflow() public {
        _borrow(1);
        (uint256 liquidity, uint256 underwriting) = _advance(RAY + 1, RAY + 1);
        assertEq(liquidity + underwriting, 0);
        market.chargePremium();
        (liquidity, underwriting) = _advance(1.5e27, RAY + 1);
        assertEq(liquidity, 1);
        assertEq(underwriting, 0);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply(), market.totalDebt());
    }

    function testFuzz_splitAndMintAlwaysEqualRoundedDebtGrowth(
        uint96 rawPrincipal,
        uint96 rawL,
        uint96 rawU,
        uint96 deltaL,
        uint96 deltaU
    ) public {
        _borrow(bound(rawPrincipal, 1, 100e18));
        uint256 oldL = RAY + uint256(rawL);
        uint256 oldU = RAY + uint256(rawU);
        _advance(oldL, oldU);
        market.chargePremium();
        uint256 debtBefore = market.totalDebt();
        uint256 creditBefore = stablecoin.creditBackedSupply();
        (uint256 liquidity, uint256 underwriting) = _advance(oldL + deltaL, oldU + deltaU);
        assertEq(liquidity + underwriting, market.totalDebt() - debtBefore);
        if (deltaU == 0) assertEq(underwriting, 0);
        if (deltaL == 0) assertEq(liquidity, 0);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply() - creditBefore, liquidity + underwriting);
        (liquidity, underwriting) = market.premium();
        assertEq(liquidity + underwriting, 0, "an unchanged checkpoint cannot mint again");
    }
}
