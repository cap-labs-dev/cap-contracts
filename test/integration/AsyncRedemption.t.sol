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
        _setMaxCapital(market, 1_000e18);

        _fundTranche(t0, supplier, 1_000e18);
        vm.prank(borrower);
        market.borrow(borrower, 500e18);

        // the first deposit paid for the seed, so this is everything the supplier holds
        uint256 held = 1_000e18 - DEAD_SHARES;
        vm.prank(supplier);
        uint256 reqId = tranche0.requestRedeem(held, supplier, supplier);

        uint256 claimablePartial = tranche0.claimableRedeemRequest(reqId, supplier);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, held);
        assertGt(tranche0.pendingRedeemRequest(reqId, supplier), 0);

        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        market.repay(type(uint256).max);

        assertEq(tranche0.claimableRedeemRequest(reqId, supplier), held);

        vm.prank(supplier);
        uint256 assets = tranche0.redeem(reqId, held, supplier, supplier);
        // short by the dead shares the first deposit seeded, which are never redeemed
        assertEq(assets, 1_000e18 - DEAD_SHARES);
        assertEq(vault.balanceOf(supplier, address(collateral)), 1_000e18 - DEAD_SHARES);
        assertEq(tranche0.totalSupply(), DEAD_SHARES);
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

        assertEq(stablecoin.maxInstantRedeem(cusdDepositor), 100e18);
        uint256 assets = stablecoin.instantRedeem(100e18, cusdDepositor, cusdDepositor);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(cusdUnderlying.balanceOf(cusdDepositor), 100e18);
    }
}
