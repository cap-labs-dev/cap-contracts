// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 re-check of round-2 R2-L5. PremiumVesting only pays opted-in balances
/// (PremiumVesting.sol:99, :200-218); a depositor who never calls `optIn()` is fully slashable
/// and earns nothing, while a 1-wei opted-in holder takes the whole vest.
contract R2_L5_OptInEconomics is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
    }

    function test_nonOptedDepositorEarnsNothing_oneWeiOptedTakesAll() public {
        MarketBundle memory b = _createReadyMarket("M");
        Tranche t = b.tranche0;
        // alice deposits without opting in
        _fundVault(alice, 1_000e18);
        _admitDepositor(address(t), alice);
        vm.startPrank(alice);
        vault.setOperator(address(t), true);
        t.deposit(1_000e18, alice);
        t.transfer(bob, 1);
        vm.stopPrank();
        vm.prank(bob);
        t.optIn();
        assertEq(t.stakedSupply(), 1, "only bob's wei is staked");

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 pot = stablecoin.balanceOf(address(t));
        vm.warp(block.timestamp + 5 days);
        emit log_named_uint("premium pot", pot);
        emit log_named_uint("bob (1 wei, opted in) claimable", t.claimable(bob));
        emit log_named_uint("alice (1000e18, not opted) claimable", t.claimable(alice));
        assertGt(t.claimable(alice), 0, "capital that is slashable must earn");
    }
}
