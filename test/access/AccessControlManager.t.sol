// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../contracts/access/Access.sol";
import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { AccessControlManager } from "../../contracts/access/AccessControlManager.sol";
import { RoleId } from "../../contracts/access/RoleId.sol";

import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { IAccessControl } from "../../contracts/interfaces/IAccessControl.sol";
import { IAccessControlManager } from "../../contracts/interfaces/IAccessControlManager.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

contract MockTarget is Initializable, Access {
    constructor() { }

    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
    }

    function restrictedFunc() external view checkAccess(this.restrictedFunc.selector) returns (bool) {
        return true;
    }

    function anotherFunc() external view checkAccess(this.anotherFunc.selector) returns (bool) {
        return true;
    }

    function thirdFunc() external view checkAccess(this.thirdFunc.selector) returns (bool) {
        return true;
    }
}

// Additional mock target to test access control in multiple contracts
contract MockTarget2 is Initializable, Access {
    constructor() { }

    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
    }

    function specialFunc() external view checkAccess(this.specialFunc.selector) returns (bool) {
        return true;
    }

    function commonFunc() external view checkAccess(this.commonFunc.selector) returns (bool) {
        return true;
    }
}

contract AccessControlManagerTest is Test, ProxyUtils {
    using RoleId for bytes4;

    AccessControl public accessControl;
    AccessControlManager public accessControlManager;
    MockTarget public mockTarget;
    MockTarget2 public mockTarget2;

    address public admin;
    address public user1;
    address public user2;
    address public unauthorizedUser;

    string constant ADMIN_ROLE = "ROLE_MANAGER_ADMIN";
    string constant TEST_ROLE = "TEST_ROLE";
    string constant SECOND_ROLE = "SECOND_ROLE";
    string constant EMPTY_ROLE = "EMPTY_ROLE";

    function getTestRoleAccesses() internal view returns (IAccessControlManager.RoleAccess[] memory) {
        IAccessControlManager.RoleAccess[] memory accesses = new IAccessControlManager.RoleAccess[](2);
        accesses[0] = IAccessControlManager.RoleAccess({
            selector: mockTarget.restrictedFunc.selector,
            contractAddress: address(mockTarget)
        });
        accesses[1] = IAccessControlManager.RoleAccess({
            selector: mockTarget.anotherFunc.selector,
            contractAddress: address(mockTarget)
        });
        return accesses;
    }

    function getSecondRoleAccesses() internal view returns (IAccessControlManager.RoleAccess[] memory) {
        IAccessControlManager.RoleAccess[] memory accesses = new IAccessControlManager.RoleAccess[](2);
        accesses[0] = IAccessControlManager.RoleAccess({
            selector: mockTarget2.specialFunc.selector,
            contractAddress: address(mockTarget2)
        });
        accesses[1] = IAccessControlManager.RoleAccess({
            selector: mockTarget2.commonFunc.selector,
            contractAddress: address(mockTarget2)
        });
        return accesses;
    }

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorizedUser = makeAddr("unauthorizedUser");

        // Deploy AccessControl
        AccessControl acImplementation = new AccessControl();
        address acProxyAddress = address(new ERC1967Proxy(address(acImplementation), ""));
        accessControl = AccessControl(acProxyAddress);
        vm.label(acProxyAddress, "AccessControl");

        // Deploy AccessControlManager
        AccessControlManager acmImplementation = new AccessControlManager();
        address acmProxyAddress = address(new ERC1967Proxy(address(acmImplementation), ""));
        accessControlManager = AccessControlManager(acmProxyAddress);
        vm.label(acmProxyAddress, "AccessControlManager");

        // Initialize AccessControl with ACM as the admin
        vm.startPrank(admin);
        accessControl.initialize(address(accessControlManager));

        // Initialize ACM with AC and make admin an admin of ACM
        accessControlManager.initialize(address(accessControl), admin);
        vm.stopPrank();

        // Deploy and initialize mock targets
        mockTarget = new MockTarget();
        mockTarget.initialize(address(accessControl));

        mockTarget2 = new MockTarget2();
        mockTarget2.initialize(address(accessControl));
    }

    function test_acmAsOnlyAdmin() public {
        // Verify ACM is the DEFAULT_ADMIN_ROLE in AccessControl
        assertTrue(
            accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), address(accessControlManager)),
            "ACM should have DEFAULT_ADMIN_ROLE"
        );

        // Verify admin cannot directly call AccessControl functions
        vm.startPrank(admin);

        // These should fail because admin doesn't have direct access to AC
        vm.expectRevert();
        accessControl.grantAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1);

        vm.expectRevert();
        accessControl.revokeAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1);

        // But admin can use ACM to grant access via roles
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.grantRole(TEST_ROLE, user1);
        vm.stopPrank();

        // User1 should now have access via ACM's role
        assertTrue(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1),
            "User should have access through ACM role"
        );

        // Verify that direct granting of access is only possible through ACM
        // ACM should have access to call these functions on AccessControl
        bytes4 grantAccessSelector = accessControl.grantAccess.selector;
        bytes4 revokeAccessSelector = accessControl.revokeAccess.selector;

        assertTrue(
            accessControl.hasAccess(grantAccessSelector, address(accessControl), address(accessControlManager)),
            "ACM should have access to grantAccess on AccessControl"
        );

        assertTrue(
            accessControl.hasAccess(revokeAccessSelector, address(accessControl), address(accessControlManager)),
            "ACM should have access to revokeAccess on AccessControl"
        );
    }

    function test_roleManagement() public {
        // Test initialization
        assertTrue(accessControlManager.hasRole(ADMIN_ROLE, admin), "Admin should have admin role");

        // Test role creation
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());

        // Test granting role
        accessControlManager.grantRole(TEST_ROLE, user1);
        vm.stopPrank();

        assertTrue(accessControlManager.hasRole(TEST_ROLE, user1), "User should have the role");
        assertTrue(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1),
            "User should have access to restricted function"
        );

        // Test using role permissions
        vm.startPrank(user1);
        bool result = mockTarget.restrictedFunc();
        assertTrue(result, "Function should execute successfully");
        vm.stopPrank();

        // Test revoking role
        vm.startPrank(admin);
        accessControlManager.revokeRole(TEST_ROLE, user1);
        vm.stopPrank();

        assertFalse(accessControlManager.hasRole(TEST_ROLE, user1), "User should no longer have the role");
        vm.startPrank(user1);
        vm.expectRevert();
        mockTarget.restrictedFunc();
        vm.stopPrank();
    }

    function test_accessModification() public {
        // Setup role with initial accesses
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.grantRole(TEST_ROLE, user1);

        // Test adding new access
        IAccessControlManager.RoleAccess memory newAccess = IAccessControlManager.RoleAccess({
            selector: mockTarget.thirdFunc.selector,
            contractAddress: address(mockTarget)
        });
        accessControlManager.addRoleAccess(TEST_ROLE, newAccess);
        vm.stopPrank();

        assertTrue(
            accessControl.hasAccess(mockTarget.thirdFunc.selector, address(mockTarget), user1),
            "User should have access to newly added function"
        );

        // Test removing access
        vm.startPrank(admin);
        IAccessControlManager.RoleAccess memory accessToRemove = IAccessControlManager.RoleAccess({
            selector: mockTarget.restrictedFunc.selector,
            contractAddress: address(mockTarget)
        });
        accessControlManager.removeRoleAccess(TEST_ROLE, accessToRemove);
        vm.stopPrank();

        assertFalse(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1),
            "User should no longer have access to removed function"
        );
        assertTrue(
            accessControl.hasAccess(mockTarget.anotherFunc.selector, address(mockTarget), user1),
            "User should still have access to other function"
        );
    }

    function test_roleQueries() public {
        // Setup roles
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.grantRole(TEST_ROLE, user1);
        accessControlManager.grantRole(TEST_ROLE, user2);
        vm.stopPrank();

        // Test addressesWithRole
        address[] memory addresses = accessControlManager.addressesWithRole(TEST_ROLE);
        assertEq(addresses.length, 2, "Should return 2 addresses");

        // Test getting role details
        IAccessControlManager.Role memory role = accessControlManager.role(TEST_ROLE);
        assertEq(role.id, TEST_ROLE, "Role ID should match");
        assertEq(role.accesses.length, 2, "Role should have 2 accesses");
    }

    function test_securityConstraints() public {
        // Test unauthorized access
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        vm.stopPrank();

        // Test admin role protection
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());

        // Can't revoke last admin
        vm.expectRevert(AccessControlManager.NoRemainingAdmins.selector);
        accessControlManager.revokeRole(ADMIN_ROLE, admin);

        // Can't remove critical permissions
        IAccessControlManager.RoleAccess memory criticalAccess = IAccessControlManager.RoleAccess({
            selector: accessControlManager.grantRole.selector,
            contractAddress: address(accessControlManager)
        });
        vm.expectRevert(AccessControlManager.CriticalRoleAccessRemoved.selector);
        accessControlManager.removeRoleAccess(ADMIN_ROLE, criticalAccess);
        vm.stopPrank();
    }

    function test_upgradeability() public {
        // Setup state before upgrade
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.grantRole(TEST_ROLE, user1);
        vm.stopPrank();

        // verify state before upgrade
        assertTrue(accessControlManager.hasRole(TEST_ROLE, user1), "User should have role before upgrade");
        assertTrue(accessControlManager.hasRole(ADMIN_ROLE, admin), "Admin should have admin role before upgrade");

        // create an upgrader role
        string memory ACM_UPGRADER_ROLE = "ACM_UPGRADER_ROLE";
        IAccessControlManager.RoleAccess[] memory upgraderAccess = new IAccessControlManager.RoleAccess[](1);
        upgraderAccess[0] =
            IAccessControlManager.RoleAccess({ selector: bytes4(0), contractAddress: address(accessControlManager) });

        address upgrader = makeAddr("upgrader");

        vm.startPrank(admin);
        accessControlManager.createRole(ACM_UPGRADER_ROLE, upgraderAccess);
        accessControlManager.grantRole(ACM_UPGRADER_ROLE, upgrader);
        vm.stopPrank();

        // Deploy new implementation
        vm.startPrank(upgrader);
        AccessControlManager newImplementation = new AccessControlManager();
        accessControlManager.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // Verify state preserved
        assertTrue(accessControlManager.hasRole(TEST_ROLE, user1), "User should still have role after upgrade");
        IAccessControlManager.Role memory role = accessControlManager.role(TEST_ROLE);
        assertEq(role.accesses.length, 2, "Role should still have 2 accesses after upgrade");

        // admin should be able to upgrade contract as well
        newImplementation = new AccessControlManager();
        vm.startPrank(admin);
        accessControlManager.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();
    }

    function test_multipleRoleHandling() public {
        // Test handling when a user has multiple roles
        vm.startPrank(admin);

        // Create two roles with different access permissions
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.createRole(SECOND_ROLE, getSecondRoleAccesses());

        // Grant both roles to the same user
        accessControlManager.grantRole(TEST_ROLE, user1);
        accessControlManager.grantRole(SECOND_ROLE, user1);
        vm.stopPrank();

        // Verify user has both roles
        assertTrue(accessControlManager.hasRole(TEST_ROLE, user1), "User should have first role");
        assertTrue(accessControlManager.hasRole(SECOND_ROLE, user1), "User should have second role");

        // Verify user has access to functions from both roles
        assertTrue(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1),
            "User should have access from first role"
        );
        assertTrue(
            accessControl.hasAccess(mockTarget2.specialFunc.selector, address(mockTarget2), user1),
            "User should have access from second role"
        );

        // Revoke one role and check that permissions from the other role remain
        vm.startPrank(admin);
        accessControlManager.revokeRole(TEST_ROLE, user1);
        vm.stopPrank();

        assertFalse(accessControlManager.hasRole(TEST_ROLE, user1), "User should no longer have first role");
        assertTrue(accessControlManager.hasRole(SECOND_ROLE, user1), "User should still have second role");

        assertFalse(
            accessControl.hasAccess(mockTarget.restrictedFunc.selector, address(mockTarget), user1),
            "User should no longer have access from first role"
        );
        assertTrue(
            accessControl.hasAccess(mockTarget2.specialFunc.selector, address(mockTarget2), user1),
            "User should still have access from second role"
        );
    }

    function test_emptyRoleHandling() public {
        // Test creating a role with no accesses
        vm.startPrank(admin);
        IAccessControlManager.RoleAccess[] memory emptyAccesses = new IAccessControlManager.RoleAccess[](0);
        accessControlManager.createRole(EMPTY_ROLE, emptyAccesses);

        // Grant empty role to user
        accessControlManager.grantRole(EMPTY_ROLE, user1);
        vm.stopPrank();

        // Verify user has role but no special permissions
        assertTrue(accessControlManager.hasRole(EMPTY_ROLE, user1), "User should have empty role");

        // Add access to the previously empty role
        vm.startPrank(admin);
        IAccessControlManager.RoleAccess memory newAccess = IAccessControlManager.RoleAccess({
            selector: mockTarget.thirdFunc.selector,
            contractAddress: address(mockTarget)
        });
        accessControlManager.addRoleAccess(EMPTY_ROLE, newAccess);
        vm.stopPrank();

        // Verify user now has the newly added access
        assertTrue(
            accessControl.hasAccess(mockTarget.thirdFunc.selector, address(mockTarget), user1),
            "User should now have access to the newly added function"
        );
    }

    function test_initializationFailure() public {
        // Test initialization with invalid parameters
        AccessControlManager newAcm = new AccessControlManager();

        // Try to initialize with zero address for accessControl
        vm.startPrank(admin);
        vm.expectRevert();
        newAcm.initialize(address(0), admin);
        vm.stopPrank();

        // Try to reinitialize an already initialized contract
        vm.startPrank(admin);
        vm.expectRevert();
        accessControlManager.initialize(address(accessControl), admin);
        vm.stopPrank();
    }

    function test_roleListRetrieval() public {
        // Create multiple roles
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.createRole(SECOND_ROLE, getSecondRoleAccesses());

        // Create empty role
        IAccessControlManager.RoleAccess[] memory emptyAccesses = new IAccessControlManager.RoleAccess[](0);
        accessControlManager.createRole(EMPTY_ROLE, emptyAccesses);
        vm.stopPrank();

        // Test getting all roles using the roles() function
        IAccessControlManager.Role[] memory allRoles = accessControlManager.roles();

        // Verify role count (should include ADMIN_ROLE + 3 new roles)
        assertEq(allRoles.length, 4, "Should return 4 roles in total");

        // Verify each role has the expected number of accesses
        for (uint i = 0; i < allRoles.length; i++) {
            string memory roleId = allRoles[i].id;

            if (keccak256(bytes(roleId)) == keccak256(bytes(EMPTY_ROLE))) {
                assertEq(allRoles[i].accesses.length, 0, "Empty role should have 0 accesses");
            } else if (keccak256(bytes(roleId)) == keccak256(bytes(TEST_ROLE))) {
                assertEq(allRoles[i].accesses.length, 2, "TEST_ROLE should have 2 accesses");
            } else if (keccak256(bytes(roleId)) == keccak256(bytes(SECOND_ROLE))) {
                assertEq(allRoles[i].accesses.length, 2, "SECOND_ROLE should have 2 accesses");
            }
        }
    }

    function test_eventEmission() public {
        // Test event emissions for role management operations
        vm.startPrank(admin);

        // Test RoleCreated event
        vm.expectEmit(true, false, false, true);
        emit AccessControlManager.RoleCreated(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());

        // Test RoleAccessAdded event
        IAccessControlManager.RoleAccess memory newAccess = IAccessControlManager.RoleAccess({
            selector: mockTarget.thirdFunc.selector,
            contractAddress: address(mockTarget)
        });

        vm.expectEmit(true, false, false, true);
        emit AccessControlManager.RoleAccessAdded(TEST_ROLE, newAccess);
        accessControlManager.addRoleAccess(TEST_ROLE, newAccess);

        // Test RoleAccessRemoved event
        IAccessControlManager.RoleAccess memory accessToRemove = IAccessControlManager.RoleAccess({
            selector: mockTarget.restrictedFunc.selector,
            contractAddress: address(mockTarget)
        });

        vm.expectEmit(true, false, false, true);
        emit AccessControlManager.RoleAccessRemoved(TEST_ROLE, accessToRemove);
        accessControlManager.removeRoleAccess(TEST_ROLE, accessToRemove);

        vm.stopPrank();
    }

    function test_adminTransfer() public {
        // Test transferring admin role to another user safely
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(admin);
        // First grant the admin role to the new admin
        accessControlManager.grantRole(ADMIN_ROLE, newAdmin);
        vm.stopPrank();

        // Verify both have admin role
        assertTrue(accessControlManager.hasRole(ADMIN_ROLE, admin), "Original admin should still have admin role");
        assertTrue(accessControlManager.hasRole(ADMIN_ROLE, newAdmin), "New admin should have admin role");

        // Test new admin can perform admin actions
        vm.startPrank(newAdmin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());
        accessControlManager.grantRole(TEST_ROLE, user1);
        vm.stopPrank();

        // Verify the new role was properly created
        assertTrue(accessControlManager.hasRole(TEST_ROLE, user1), "User should have role created by new admin");

        // Original admin can revoke their own admin role now that there's another admin
        vm.startPrank(admin);
        accessControlManager.revokeRole(ADMIN_ROLE, admin);
        vm.stopPrank();

        assertFalse(accessControlManager.hasRole(ADMIN_ROLE, admin), "Original admin should no longer have admin role");
        assertTrue(accessControlManager.hasRole(ADMIN_ROLE, newAdmin), "New admin should still have admin role");

        // Original admin can no longer perform admin actions
        vm.startPrank(admin);
        vm.expectRevert();
        accessControlManager.createRole(SECOND_ROLE, getSecondRoleAccesses());
        vm.stopPrank();
    }

    function test_roleAccessEdgeCases() public {
        // Test duplicate access addition
        vm.startPrank(admin);
        accessControlManager.createRole(TEST_ROLE, getTestRoleAccesses());

        // Try to add an access that already exists
        IAccessControlManager.RoleAccess memory duplicateAccess = IAccessControlManager.RoleAccess({
            selector: mockTarget.restrictedFunc.selector,
            contractAddress: address(mockTarget)
        });

        // Should not revert but also not duplicate the access
        accessControlManager.addRoleAccess(TEST_ROLE, duplicateAccess);

        // Check role still has the correct number of accesses
        IAccessControlManager.Role memory role = accessControlManager.role(TEST_ROLE);
        assertEq(role.accesses.length, 2, "Role should still have 2 accesses without duplication");

        // Test removing non-existent access
        IAccessControlManager.RoleAccess memory nonExistentAccess = IAccessControlManager.RoleAccess({
            selector: bytes4(keccak256("nonExistentFunction()")),
            contractAddress: address(mockTarget)
        });

        // Should not revert when removing non-existent access
        accessControlManager.removeRoleAccess(TEST_ROLE, nonExistentAccess);

        // Role accesses should remain unchanged
        role = accessControlManager.role(TEST_ROLE);
        assertEq(role.accesses.length, 2, "Role should still have 2 accesses after removing non-existent access");
        vm.stopPrank();
    }

    function test_nonExistentRoleQueries() public {
        // Test behavior when querying non-existent roles
        string memory NON_EXISTENT_ROLE = "NON_EXISTENT_ROLE";

        // Test hasRole for non-existent role
        assertFalse(accessControlManager.hasRole(NON_EXISTENT_ROLE, user1), "User should not have non-existent role");

        // Test addressesWithRole for non-existent role
        address[] memory addresses = accessControlManager.addressesWithRole(NON_EXISTENT_ROLE);
        assertEq(addresses.length, 0, "Should return empty array for non-existent role");

        // Test role details for non-existent role
        IAccessControlManager.Role memory roleInfo = accessControlManager.role(NON_EXISTENT_ROLE);
        assertEq(roleInfo.id, NON_EXISTENT_ROLE, "Role ID should match");
        assertEq(roleInfo.accesses.length, 0, "Non-existent role should have 0 accesses");
    }
}
