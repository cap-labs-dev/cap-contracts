// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-2 port of round-1 B1b_ControlAndUnderwriter (H-2). Assertions unchanged.
contract R1_H2b_ControlAndUnderwriter is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    FloatingMarket internal market;
    Tranche internal senior;
    Tranche internal junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("Market A");
        market = FloatingMarket(m);
        senior = Tranche(s);
        junior = Tranche(j);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(type(uint256).max);
    }

    function test_B1_control_noOutOfOrderSettlement_lockHolds() public {
        _fundTranche(address(senior), supplier, 1_000e18);
        _fundTranche(address(junior), alice, 100e18);
        _fundTranche(address(junior), bob, 100e18);

        uint256 aliceShares = junior.balanceOf(alice);
        vm.prank(alice);
        uint256 idA = junior.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        junior.requestRedeem(100e18, bob, bob); // bob does NOT claim

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);

        assertEq(junior.unlockedSupply(), 0);
        assertEq(junior.claimableRedeemRequest(idA, alice), 0, "correctly locked when nothing settled out of order");
        vm.prank(alice);
        vm.expectRevert();
        junior.redeem(idA, aliceShares, alice, alice);
    }

    function test_B1_underwriterClaimableMisreportedAfterAllocate() public {
        Underwriter uw = _deployUnderwriter();
        _admitDepositor(address(senior), address(uw));
        uw.addTranche(address(senior));
        // no default tranche: deposits sit idle in the vault, so unlockedSupply == full supply

        _fundUnderwriter(address(uw), alice, 100e18);
        _fundUnderwriter(address(uw), bob, 100e18);
        uint256 aliceShares = uw.balanceOf(alice);

        vm.prank(alice);
        uint256 idA = uw.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 idB = uw.requestRedeem(100e18, bob, bob);
        vm.prank(bob);
        uw.redeem(idB, 100e18, bob, bob); // out of order

        uw.allocate(address(senior), vault.balanceOf(address(uw), address(collateral)));
        assertEq(uw.unlockedSupply(), 0, "nothing idle to pay a claim");

        uint256 claimable = uw.claimableRedeemRequest(idA, alice);
        emit log_named_uint("uw.claimable(idA, alice) with unlocked==0", claimable);
        assertLe(claimable, uw.unlockedSupply(), "claimable must never exceed unlockedSupply");
    }
}
