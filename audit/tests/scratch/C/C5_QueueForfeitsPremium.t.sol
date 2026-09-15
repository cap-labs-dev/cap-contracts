// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-C / H12: queued shares are excluded from stakedSupply, so they earn nothing, yet they stay
/// in the tranche's supply and assets and are slashed exactly like held shares. In a single
/// tranche market the sole underwriter who queues (the only way to reserve an exit) forfeits the
/// entire underwriter premium to stakedStablecoin while remaining 100% exposed until the borrower
/// chooses to repay.
contract C5_QueueForfeitsPremium is CapDeployer {
    FloatingMarket market;
    Tranche tranche;
    address alice = makeAddr("alice");

    function setUp() public {
        _deployCap();
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        (address m, address[] memory ts) = _createMarket("Single", defaultMarketOwner, defaultBorrower, w);
        market = FloatingMarket(m);
        tranche = Tranche(ts[0]);
        _setMarketSlopes(m);
    }

    function test_H12_lockedQueuedUnderwriterEarnsNothingButIsSlashed() public {
        _fundTranche(address(tranche), alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        // alice wants out; she queues everything and claims what the buffer allows
        uint256 aliceShares = tranche.balanceOf(alice);
        vm.prank(alice);
        uint256 id = tranche.requestRedeem(aliceShares, alice, alice);
        uint256 claimable = tranche.claimableRedeemRequest(id, alice);
        vm.prank(alice);
        tranche.redeem(id, claimable, alice, alice);
        emit log_named_uint("shares alice could exit", claimable);
        emit log_named_uint("shares still queued and locked by debt", tranche.redemptionQueue());
        assertEq(tranche.stakedSupply(), 0, "nothing is 'staked' any more");

        uint256 stcBefore = stablecoin.balanceOf(capConfig.stablecoinYield);
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
        uint256 toTranche = stablecoin.balanceOf(address(tranche));
        uint256 toLenders = stablecoin.balanceOf(capConfig.stablecoinYield) - stcBefore;
        emit log_named_uint("30d underwriter premium routed to tranche", toTranche);
        emit log_named_uint("30d premium (liquidity + redirected underwriter) routed to stcUSD", toLenders);

        // and she still carries the whole slash
        oracle.setPrice(address(collateral), 0.5e18);
        _mintStable(defaultLiquidator, 50e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 50e18);
        emit log_named_uint("alice queued position value after slash", tranche.previewRedeem(tranche.redemptionQueue()));

        assertGt(toTranche, 0, "capital that is locked and slashable must be paid for underwriting");
    }
}
