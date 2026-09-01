// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract AsyncRedemptionTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal supplier = makeAddr("supplier");
    address internal cusdHolder = makeAddr("cusdHolder");
    address internal cusdDepositor = makeAddr("cusdDepositor");

    function setUp() public {
        _deployCap();
    }

    function test_tranche_asyncRedemption_pendingUntilRepaid() public {
        address marketAddr;
        address t0;
        (marketAddr, t0,) = _createMarket("Market A");
        FloatingMarket market = FloatingMarket(marketAddr);
        Tranche tranche0 = Tranche(t0);

        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        market.setFixedCreditLimit(1_000e18);

        _fundTranche(t0, supplier, 1_000e18);
        vm.prank(borrower);
        market.borrow(borrower, 500e18);

        vm.prank(supplier);
        uint256 reqId = tranche0.requestRedeem(1_000e18, supplier, supplier);

        uint256 claimablePartial = tranche0.claimableRedeemRequest(reqId, supplier);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, 1_000e18);
        assertGt(tranche0.pendingRedeemRequest(reqId, supplier), 0);

        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        market.repay(type(uint256).max);

        assertEq(tranche0.claimableRedeemRequest(reqId, supplier), 1_000e18);

        vm.prank(supplier);
        uint256 assets = tranche0.redeem(reqId, 1_000e18, supplier, supplier);
        assertEq(assets, 1_000e18);
        assertEq(vault.balanceOf(supplier, address(collateral)), 1_000e18);
        assertEq(tranche0.totalSupply(), 0);
    }

    function test_stablecoin_asyncRedemption_pendingUntilBacked() public {
        _mintStable(cusdHolder, 100e18);
        assertEq(stablecoin.unlockedSupply(), 0);

        vm.prank(cusdHolder);
        uint256 reqId = stablecoin.requestRedeem(100e18, cusdHolder, cusdHolder);

        assertEq(stablecoin.pendingRedeemRequest(reqId, cusdHolder), 100e18);
        assertEq(stablecoin.claimableRedeemRequest(reqId, cusdHolder), 0);

        cusdUnderlying.mint(cusdDepositor, 100e18);
        vm.startPrank(cusdDepositor);
        cusdUnderlying.approve(address(stablecoin), 100e18);
        stablecoin.deposit(100e18, cusdDepositor);
        vm.stopPrank();

        assertEq(stablecoin.unlockedSupply(), 100e18);
        assertEq(stablecoin.claimableRedeemRequest(reqId, cusdHolder), 100e18);

        vm.prank(cusdHolder);
        uint256 assets = stablecoin.redeem(reqId, 100e18, cusdHolder, cusdHolder);
        assertEq(assets, 100e18);
        assertEq(cusdUnderlying.balanceOf(cusdHolder), 100e18);
    }

    function test_stablecoin_instantRedeem_whenBacked() public {
        cusdUnderlying.mint(cusdDepositor, 100e18);
        vm.startPrank(cusdDepositor);
        cusdUnderlying.approve(address(stablecoin), 100e18);
        stablecoin.deposit(100e18, cusdDepositor);

        assertEq(stablecoin.maxRedeem(cusdDepositor), 100e18);
        uint256 assets = stablecoin.redeem(100e18, cusdDepositor, cusdDepositor);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(cusdUnderlying.balanceOf(cusdDepositor), 100e18);
    }
}
