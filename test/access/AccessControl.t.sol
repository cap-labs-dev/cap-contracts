// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../contracts/access/Access.sol";
import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { RoleId } from "../../contracts/access/RoleId.sol";
import { IAccessControl } from "../../contracts/interfaces/IAccessControl.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
// Mock contract to test access control on

contract MockTarget is Initializable, Access {
    constructor() { }

    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
    }

    function restrictedFunc() external view checkAccess(this.restrictedFunc.selector) returns (bool) {
        return true;
    }
}

contract AccessControlTest is Test {
    using RoleId for bytes4;

    AccessControl public accessControl;
    MockTarget public mockTarget;

    address public admin;
    address public user;
    address public unauthorizedUser;

    function setUp() public {
        // Setup users
        admin = makeAddr("admin");
        user = makeAddr("user");
        unauthorizedUser = makeAddr("unauthorizedUser");

        // Deploy AccessControl implementation and initialize it
        AccessControl implementation = new AccessControl();

        // Deploy proxy and initialize it
        address proxyAddress = address(new ERC1967Proxy(address(implementation), ""));
        accessControl = AccessControl(proxyAddress);
        accessControl.initialize(admin);

        // Deploy mock target
        mockTarget = new MockTarget();
        mockTarget.initialize(address(accessControl));

        // Grant access to the user for the restricted function
        vm.startPrank(admin);
        accessControl.grantAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user);
        vm.stopPrank();
    }

    function test_initialize() public {
        // Deploy a new AccessControl to test initialization
        AccessControl newImplementation = new AccessControl();
        address newAdmin = makeAddr("newAdmin");

        address proxyAddress = address(new ERC1967Proxy(address(newImplementation), ""));
        AccessControl newAccessControl = AccessControl(proxyAddress);
        newAccessControl.initialize(newAdmin);

        // Check that the new admin has the DEFAULT_ADMIN_ROLE and access management roles
        assertTrue(
            newAccessControl.hasRole(newAccessControl.DEFAULT_ADMIN_ROLE(), newAdmin),
            "Admin should have DEFAULT_ADMIN_ROLE"
        );
        assertTrue(
            newAccessControl.hasRole(newAccessControl.grantAccess.selector.roleId(address(newAccessControl)), newAdmin),
            "Admin should have grantAccess role"
        );
    }

    function test_access_management() public {
        // User should have access to the restricted function initially
        assertTrue(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user),
            "User should have access to restricted function"
        );

        // User should be able to call the restricted function
        vm.startPrank(user);
        bool result = mockTarget.restrictedFunc();
        assertTrue(result, "Restricted function should execute successfully");
        vm.stopPrank();

        // Unauthorized user should not have access to the restricted function
        vm.startPrank(unauthorizedUser);
        assertFalse(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), unauthorizedUser),
            "Unauthorized user should not have access to restricted function"
        );

        // Unauthorized user should not be able to call the restricted function
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        mockTarget.restrictedFunc();
        vm.stopPrank();

        // Admin revokes user's access
        vm.startPrank(admin);
        accessControl.revokeAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user);
        vm.stopPrank();

        // User should no longer have access
        assertFalse(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user),
            "User should no longer have access after revocation"
        );

        // User can no longer call the restricted function
        vm.startPrank(user);
        vm.expectRevert();
        mockTarget.restrictedFunc();
        vm.stopPrank();
    }

    function test_role_generation() public view {
        bytes32 role = accessControl.role(mockTarget.restrictedFunc.selector, address(mockTarget));
        bytes32 expectedRole = mockTarget.restrictedFunc.selector.roleId(address(mockTarget));

        assertEq(role, expectedRole, "Role ID should be generated correctly");
    }

    function test_access_permissions() public {
        // Unauthorized user tries to grant access
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        accessControl.grantAccess(mockTarget.restrictedFunc.selector, address(mockTarget), unauthorizedUser);
        vm.stopPrank();

        // Admin tries to revoke their own access to grantAccess
        vm.startPrank(admin);
        bytes4 grantAccessSelector = accessControl.grantAccess.selector;
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.CannotRevokeSelf.selector));
        accessControl.revokeAccess(grantAccessSelector, address(accessControl), admin);
        vm.stopPrank();
    }

    function test_upgradeability() public {
        // New implementation with same interface
        AccessControl newImplementation = new AccessControl();

        // Admin performs the upgrade
        vm.startPrank(admin);
        accessControl.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // State should be preserved after upgrade
        assertTrue(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user),
            "User access should be preserved after upgrade"
        );

        // Unauthorized user cannot upgrade
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        accessControl.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();
    }
}
