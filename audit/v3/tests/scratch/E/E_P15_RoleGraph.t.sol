// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// WS-E / P15: Registry role graph edge cases.

import { Registry } from "../../../../../contracts/cap/Registry.sol";
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../../../../contracts/interfaces/IFloatingMarket.sol";
import { IRegistry } from "../../../../../contracts/interfaces/IRegistry.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../../../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../../../../contracts/utils/CapRoles.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract E_P15_RoleGraph is CapDeployer {
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;
    address internal market;
    address[] internal tranches;
    uint64 internal ownerRole;

    function setUp() public {
        _deployCap();
        (market, tranches) = _createMarket("p15", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        ownerRole = _operatorRoleOf(defaultMarketOwner);
    }

    /// setDepositorRole has no PublicRole / isOperatorRole guard: the market owner can open a
    /// tranche to PUBLIC or wire it to a protocol role. setBorrowerRole rejects the same inputs.
    function test_setDepositorRole_acceptsPublicAndProtocolRoles_setBorrowerRoleDoesNot() public {
        vm.prank(defaultMarketOwner);
        vm.expectRevert(IRegistry.PublicRole.selector);
        IBaseMarket(market).setBorrowerRole(PUBLIC_ROLE);
        vm.prank(defaultMarketOwner);
        vm.expectRevert(IRegistry.NotOperatorRole.selector);
        IBaseMarket(market).setBorrowerRole(CapRoles.GUARDIAN);

        // tranche -> PUBLIC: anyone may now deposit
        ITranche(tranches[1]).setDepositorRole(PUBLIC_ROLE); // owner == this
        assertEq(accessManager.getTargetFunctionRole(tranches[1], IERC4626.deposit.selector), PUBLIC_ROLE);
        address stranger = makeAddr("stranger");
        _fundVault(stranger, 10e18);
        vm.startPrank(stranger);
        vault.setOperator(tranches[1], true);
        Tranche(tranches[1]).deposit(10e18, stranger);
        vm.stopPrank();
        assertGt(Tranche(tranches[1]).balanceOf(stranger), 0, "permissionless junior deposit");

        // tranche -> GUARDIAN / PROTOCOL also accepted
        ITranche(tranches[0]).setDepositorRole(CapRoles.GUARDIAN);
        assertEq(accessManager.getTargetFunctionRole(tranches[0], IERC4626.deposit.selector), CapRoles.GUARDIAN);
        ITranche(tranches[0]).setDepositorRole(CapRoles.PROTOCOL);
        assertEq(accessManager.getTargetFunctionRole(tranches[0], IERC4626.deposit.selector), CapRoles.PROTOCOL);

        // underwriter -> PUBLIC accepted too
        address uw = address(_deployUnderwriter());
        IUnderwriter(uw).setDepositorRole(PUBLIC_ROLE);
        assertEq(accessManager.getTargetFunctionRole(uw, IERC4626.deposit.selector), PUBLIC_ROLE);
    }

    /// setBorrowerRole accepts an operator role administered by another party; that party then
    /// controls who may borrow from this market (grant/revoke without the owner's consent).
    function test_setBorrowerRole_crossOwnerRoleHandsMembershipToOtherAdmin() public {
        address ownerB = makeAddr("ownerB");
        uint64 roleB = _assignOperator(ownerB); // admin = GOVERNOR in the harness
        // B creates a borrower group it administers
        address[][] memory members = new address[][](1);
        members[0] = new address[](0);
        vm.prank(address(this));
        uint64 borrowersOfB = registry.createChildRoles(roleB, members)[0];
        assertEq(accessManager.getRoleAdmin(borrowersOfB), roleB);

        // A (this market's owner) points its borrow selectors at B's group
        vm.prank(defaultMarketOwner);
        IBaseMarket(market).setBorrowerRole(borrowersOfB);

        // B adds mallory; A never consented and cannot revoke (A is not roleB)
        address mallory = makeAddr("mallory");
        vm.prank(ownerB);
        accessManager.grantRole(borrowersOfB, mallory, 0);
        (bool can,) = accessManager.canCall(mallory, market, IFloatingMarket.borrow.selector);
        assertTrue(can, "B's member can borrow from A's market");
        vm.prank(defaultMarketOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, defaultMarketOwner, roleB)
        );
        accessManager.revokeRole(borrowersOfB, mallory);
    }

    /// createTranche uses hasRole and ignores the execution delay: an owner-role member granted
    /// with a delay must schedule setLtv but can createTranche immediately.
    function test_createTranche_ignoresExecutionDelay() public {
        address delayed = makeAddr("delayedOwner");
        accessManager.grantRole(ownerRole, delayed, 1 days);
        (bool member, uint32 delay) = accessManager.hasRole(ownerRole, delayed);
        assertTrue(member);
        assertEq(delay, 1 days);

        vm.prank(delayed);
        vm.expectRevert(); // AccessManagerNotScheduled
        IBaseMarket(market).setLtv(0.5e27);

        uint256[] memory w = new uint256[](3);
        w[0] = 0.5e27;
        w[1] = 0.3e27;
        w[2] = 0.2e27;
        vm.prank(delayed);
        address t = registry.createTranche(market, address(collateral), w);
        assertTrue(t != address(0), "createTranche bypassed the delay");
    }

    /// marketOwnerRole is whatever setLtv is wired to. Rehoming only setLtv changes who may
    /// createTranche and who administers new depositor roles, while the other six owner
    /// selectors stay with the original role.
    function test_marketOwnerRole_followsSetLtvOnly() public {
        uint64 other = _assignOperator(makeAddr("other"));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = IBaseMarket.setLtv.selector;
        accessManager.setTargetFunctionRole(market, sel, other);
        assertEq(registry.marketOwnerRole(market), other);
        assertEq(
            accessManager.getTargetFunctionRole(market, IBaseMarket.setTrancheWeights.selector),
            ownerRole,
            "split owner"
        );
    }

    /// BaseMarket.setDepositorRole wires deposit/mint on a market that has neither function.
    function test_marketSetDepositorRole_wiresDeadSelectors() public {
        uint64 r = _assignOperator(makeAddr("dep"));
        vm.prank(defaultMarketOwner);
        IBaseMarket(market).setDepositorRole(r);
        assertEq(accessManager.getTargetFunctionRole(market, IERC4626.deposit.selector), r);
        (bool ok,) = market.call(abi.encodeWithSelector(IERC4626.deposit.selector, 1, address(this)));
        assertFalse(ok, "no such function on a market");
    }

    /// createChildRoles: any parent (ADMIN, GOVERNOR, a depositor role) is accepted; the caller
    /// gains nothing over the parent; ids come from one counter shared with tranche depositor
    /// roles, so they never collide.
    function test_createChildRoles_arbitraryParent_noEscalation_sharedCounter() public {
        address wl = makeAddr("wl");
        accessManager.grantRole(CapRoles.WHITELISTED, wl, 0);
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = wl;
        vm.prank(wl);
        uint64 rAdmin = registry.createChildRoles(CapRoles.ADMIN, members)[0];
        assertEq(accessManager.getRoleAdmin(rAdmin), CapRoles.ADMIN);
        (bool isAdmin,) = accessManager.hasRole(CapRoles.ADMIN, wl);
        assertFalse(isAdmin);
        (bool isGov,) = accessManager.hasRole(CapRoles.GOVERNOR, wl);
        assertFalse(isGov);
        // parent = a (non-operator) depositor role is accepted
        uint64 dep = _depositorRole(tranches[0]);
        vm.prank(wl);
        uint64 rDep = registry.createChildRoles(dep, members)[0];
        assertEq(accessManager.getRoleAdmin(rDep), dep);
        // new tranche depositor role id continues the same counter
        uint256[] memory w = new uint256[](3);
        w[0] = 0.5e27;
        w[1] = 0.3e27;
        w[2] = 0.2e27;
        address t = registry.createTranche(market, address(collateral), w);
        assertEq(_depositorRole(t), rDep + 1, "shared counter, no collision");
        assertFalse(registry.isOperatorRole(_depositorRole(t)));
    }

    /// A fresh market's borrow selectors resolve to ADMIN until the owner sets a borrower role;
    /// ADMIN can borrow from it (needs collateral, so no loss - but it is a by-omission ADMIN power).
    function test_freshMarket_borrowResolvesToAdminByOmission() public {
        (address fresh,) =
            registry.createFloatingMarket(_uniformAssets(2), capConfig.defaultTrancheWeights, "fresh", ownerRole);
        assertEq(accessManager.getTargetFunctionRole(fresh, IFloatingMarket.borrow.selector), CapRoles.ADMIN);
        (bool can,) = accessManager.canCall(address(this), fresh, IFloatingMarket.borrow.selector);
        assertTrue(can, "ADMIN may borrow from a market with no borrower role");
    }
}
