// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { N2Test } from "../../N2/N2.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Angle (c): is there ANY role-gated sequence that books a reserve loss into badDebt without
/// corrupting creditBackedSupply? Candidate: MARKET does fundCreditBacked(L) then recognizeBadDebt(L).
contract VerifyAeraLoss is N2Test {
    function test_verify_fundCreditBackedThenRecognize_doesNotRepairBacking() public {
        _dep(alice, 500e18);
        _dep(bob, 500e18);
        sc.invest(500e18);
        uint256 L = aera.lose(IERC20(address(asset)), 2_000); // 100
        sc.recall(400e18);
        uint256 realReserve = asset.balanceOf(address(sc));
        assertEq(realReserve, 900e18);

        // the "workaround": mint L credit-backed to the pot, immediately write it off
        sc.fundCreditBacked(L);
        sc.recognizeBadDebt(L);
        assertEq(sc.creditBackedSupply(), 0, "credit unchanged - ok");
        assertEq(sc.badDebt(), L, "badDebt now L");
        // but totalSupply also rose by L, so totalAssets is still the pre-loss 1000
        assertEq(sc.totalAssets(), 1_000e18, "totalAssets still overstates by L");
        // sum payable if everyone redeems = backing = 1000 > real 900: still short by exactly L
        uint256 payable_ = sc.previewRedeem(sc.totalSupply());
        assertEq(payable_, 1_000e18);
        assertEq(payable_ - realReserve, L, "shortfall unchanged; workaround only dilutes via the pot");
        // and unlockedSupply is unchanged, so the redemption window still promises 1000 against 900
        assertEq(sc.unlockedSupply(), 1_000e18);
    }

    /// @dev Loss distribution: with N redeemers exiting in order after a loss L, exactly the last
    /// L of unlocked supply is unpayable. Queued (settled) claims are hit the same way.
    function test_verify_lossIsConcentratedNotProRata() public {
        _dep(alice, 400e18);
        _dep(bob, 400e18);
        address carol = makeAddr("carol");
        asset.mint(carol, 200e18);
        vm.prank(carol);
        asset.approve(address(sc), type(uint256).max);
        vm.prank(carol);
        sc.deposit(200e18, carol);
        sc.invest(1_000e18);
        aera.lose(IERC20(address(asset)), 1_000); // 10% = 100
        sc.recall(900e18);
        vm.prank(alice);
        sc.redeem(400e18, alice, alice);
        vm.prank(bob);
        sc.redeem(400e18, bob, bob);
        assertEq(asset.balanceOf(alice), 1_000e18, "alice par");
        assertEq(asset.balanceOf(bob), 1_000e18, "bob par");
        assertEq(asset.balanceOf(address(sc)), 100e18);
        assertEq(sc.maxRedeem(carol), 200e18, "advertised 200");
        vm.prank(carol);
        vm.expectRevert();
        sc.redeem(200e18, carol, carol);
        vm.prank(carol);
        sc.redeem(100e18, carol, carol);
        assertEq(sc.balanceOf(carol), 100e18, "last holder eats 100% of L");
    }
}
