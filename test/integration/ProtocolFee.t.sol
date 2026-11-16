// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IPremiumVesting } from "../../contracts/interfaces/IPremiumVesting.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice The protocol fee is taken off both premium legs at the charge and minted to the
/// receiver in cUSD. The borrower's charge and the credit-backed supply are unchanged.
contract ProtocolFeeTest is CapDeployer {
    FloatingMarket internal market;
    address internal senior;
    address internal junior;
    address internal receiver = makeAddr("fee receiver");

    function setUp() public {
        _deployCap();
        (address m, address t0, address t1) = _createMarket("Fee switch");
        market = FloatingMarket(m);
        senior = t0;
        junior = t1;
        _fundTranche(senior, makeAddr("senior supplier"), 1_000e18);
        _fundTranche(junior, makeAddr("junior supplier"), 1_000e18);
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

    function _borrowAndGrow() internal returns (uint256 liquidity, uint256 underwriting) {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        vm.warp(block.timestamp + 1);
        _indices(1.2e27, 1.2e27);
        (liquidity, underwriting) = market.premium();
        assertEq(liquidity, 24e18);
        assertEq(underwriting, 20e18);
    }

    function test_feeOffByDefault() public {
        _borrowAndGrow();
        market.chargePremium();
        assertEq(stablecoin.balanceOf(receiver), 0);
        assertEq(stablecoin.creditBackedSupply(), 144e18);
    }

    function test_floatingChargeMintsFeeToReceiver() public {
        registry.setProtocolFee(receiver, 0.1e27, 0.25e27);
        _borrowAndGrow();

        uint256 stableBefore = stablecoin.balanceOf(address(stablecoin));
        uint256 seniorBefore = stablecoin.balanceOf(senior);
        uint256 juniorBefore = stablecoin.balanceOf(junior);

        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeProtocolFee(receiver, 2.4e18, 5e18);
        market.chargePremium();

        // receiver gets plain cUSD, not vested
        assertEq(stablecoin.balanceOf(receiver), 7.4e18);
        assertEq(IPremiumVesting(address(stablecoin)).pendingPremium(receiver), 0);

        // what reaches the pools is the charge less the fee
        assertEq(stablecoin.balanceOf(address(stablecoin)) - stableBefore, 24e18 - 2.4e18);
        uint256 toTranches =
            (stablecoin.balanceOf(senior) - seniorBefore) + (stablecoin.balanceOf(junior) - juniorBefore);
        assertEq(toTranches, 20e18 - 5e18);

        // borrower debt and credit-backed supply are what they were without the fee
        assertEq(market.totalDebt(), 144e18);
        assertEq(stablecoin.creditBackedSupply(), 144e18);
    }

    function test_feeSwitchedOffMidLifeStopsCharging() public {
        registry.setProtocolFee(receiver, 0.1e27, 0.25e27);
        _borrowAndGrow();
        market.chargePremium();
        assertEq(stablecoin.balanceOf(receiver), 7.4e18);

        registry.setProtocolFee(address(0), 0, 0);
        vm.warp(block.timestamp + 1);
        _indices(1.44e27, 1.44e27);
        market.chargePremium();
        assertEq(stablecoin.balanceOf(receiver), 7.4e18);
        assertEq(stablecoin.creditBackedSupply(), market.totalDebt());
    }

    function test_fixedBorrowChargesFeeOnBothLegs() public {
        registry.setProtocolFee(receiver, 0.1e27, 0.25e27);
        (address deployed, address fixedSenior,) = _createFixedMarket("Fixed fee");
        FixedMarket fixedMarket = FixedMarket(deployed);
        fixedMarket.setUnderwriterRate(0.2e27);
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        _setMaxCapital(fixedMarket, 10_000e18);
        _fundTranche(fixedSenior, makeAddr("fixed supplier"), 10_000e18);
        _depositStable(makeAddr("reserve holder"), 10_000e18);
        vm.warp(block.timestamp + 20 * irm.averagingPeriod());
        irm.updateLiquidityRate();

        (uint256 liquidity, uint256 underwriting) = fixedMarket.premiumForBorrow(1_000e18, 30 days);
        assertGt(liquidity, 0);
        assertGt(underwriting, 0);
        uint256 expectedFee = liquidity / 10 + underwriting / 4;

        uint256 supplyBefore = stablecoin.creditBackedSupply();
        vm.prank(defaultBorrower);
        (, uint256 principal) = fixedMarket.borrow(defaultBorrower, 1_000e18, 30 days, type(uint256).max);
        assertEq(principal, 1_000e18);

        assertApproxEqAbs(stablecoin.balanceOf(receiver), expectedFee, 2);
        assertEq(stablecoin.creditBackedSupply() - supplyBefore, 1_000e18 + liquidity + underwriting);
        assertEq(fixedMarket.totalDebt(), 1_000e18 + liquidity + underwriting);
    }
}
