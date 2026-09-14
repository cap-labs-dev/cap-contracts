// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-14 (C5). `requestRedeem` moves the shares to the vault itself
/// (ERC7540AsyncRedeem.sol:87), which is never opted in (PremiumVesting.optIn :116 refuses
/// `address(this)`), so queued shares leave `staked` and earn nothing while they stay in
/// `totalAssets`/`healthiness` and are slashed. No cancel entry point exists
/// (`CancelExceedsPending` is declared, IERC7540AsyncRedeem.sol:32, and unused).
contract R1_L14_QueueForfeitsPremium is CapDeployer {
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

    function test_L14_lockedQueuedUnderwriterEarnsNothingButIsSlashed() public {
        _fundTranche(address(tranche), alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        uint256 aliceShares = tranche.balanceOf(alice);
        vm.prank(alice);
        uint256 id = tranche.requestRedeem(aliceShares, alice, alice);
        uint256 claimable = tranche.claimableRedeemRequest(id, alice);
        vm.prank(alice);
        tranche.redeem(id, claimable, alice, alice);
        emit log_named_uint("shares alice could exit", claimable);
        emit log_named_uint("shares still queued and locked by debt", tranche.redemptionQueue());
        emit log_named_uint("stakedSupply after queue", tranche.stakedSupply());
        assertEq(tranche.stakedSupply(), 0, "nothing is 'staked' any more");
        emit log_named_uint("market totalCapital (incl. queued)", market.totalCapital());
        emit log_named_uint("healthiness (ray)", market.healthiness());

        uint256 cbs0 = stablecoin.creditBackedSupply();
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
        uint256 toTranche = stablecoin.balanceOf(address(tranche));
        uint256 minted = stablecoin.creditBackedSupply() - cbs0;
        emit log_named_uint("30d underwriter premium routed to tranche", toTranche);
        emit log_named_uint("30d premium routed to cUSD holders instead", minted - toTranche);

        (bool ok,) = address(tranche).call(abi.encodeWithSignature("cancelRedeem(uint256)", id));
        emit log_named_string("cancelRedeem(uint256)", ok ? "exists" : "no such function");
        assertFalse(ok, "no cancel entry point");

        uint256 queuedValueBefore = tranche.convertToAssets(tranche.redemptionQueue());
        _setPrice(address(collateral), 0.5e18);
        _mintStable(defaultLiquidator, 50e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 50e18);
        uint256 queuedValueAfter = tranche.convertToAssets(tranche.redemptionQueue());
        emit log_named_uint("alice queued position (assets) before slash", queuedValueBefore);
        emit log_named_uint("alice queued position (assets) after slash", queuedValueAfter);
        assertLt(queuedValueAfter, queuedValueBefore, "queued shares were slashed");

        assertGt(toTranche, 0, "capital that is locked and slashable must be paid for underwriting");
    }
}
