// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { EigenOperator } from "../../contracts/delegation/providers/eigenlayer/EigenOperator.sol";
import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { IAllocationManager } from "../../contracts/delegation/providers/eigenlayer/interfaces/IAllocationManager.sol";
import { IDelegationManager } from "../../contracts/delegation/providers/eigenlayer/interfaces/IDelegationManager.sol";
import { IRewardsCoordinator } from "../../contracts/delegation/providers/eigenlayer/interfaces/IRewardsCoordinator.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { console } from "forge-std/console.sol";

contract EigenOperatorTest is TestDeployer {
    EigenOperator eigenOperator;
    EigenServiceManager eigenServiceManager;
    address operator;
    address restaker;
    address serviceManager;
    string constant METADATA = "test-operator-metadata";

    function setUp() public {
        _deployCapTestEnvironment();
        eigenServiceManager = EigenServiceManager(env.eigen.eigenConfig.eigenServiceManager);
        serviceManager = address(eigenServiceManager);
        operator = env.testUsers.agents[1];
        restaker = env.testUsers.restakers[1];

        // Deploy a fresh EigenOperator for testing
        eigenOperator = EigenOperator(eigenServiceManager.getEigenOperator(operator));
    }

    // ============ INITIALIZATION TESTS ============

    function test_initialize_sets_correct_values() public view {
        assertEq(eigenOperator.eigenServiceManager(), serviceManager);
        assertEq(eigenOperator.operator(), operator);
        assertEq(eigenOperator.restaker(), restaker);
    }

    // ============ TOTP FUNCTIONALITY TESTS ============

    function test_totp_calculation() public view {
        uint256 currentTotp = eigenOperator.currentTotp();
        uint256 expectedTotp = block.timestamp / (28 days);
        assertEq(currentTotp, expectedTotp);
    }

    function test_totp_expiry_timestamp() public view {
        uint256 expiryTimestamp = eigenOperator.getCurrentTotpExpiryTimestamp();
        uint256 currentTotp = eigenOperator.currentTotp();
        uint256 expectedExpiry = (currentTotp + 1) * (28 days);
        assertEq(expiryTimestamp, expectedExpiry);
    }

    function test_totp_boundary_transition() public {
        uint256 initialTotp = eigenOperator.currentTotp();

        // Travel to just before the next TOTP period
        uint256 nextPeriodStart = (initialTotp + 1) * (28 days);
        vm.warp(nextPeriodStart - 1);

        assertEq(eigenOperator.currentTotp(), initialTotp);

        // Travel to the next TOTP period
        vm.warp(nextPeriodStart);
        assertEq(eigenOperator.currentTotp(), initialTotp + 1);
    }

    function test_totp_digest_calculation() public view {
        bytes32 digest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        assertTrue(digest != bytes32(0));
    }

    function test_totp_digest_changes_with_different_staker() public view {
        bytes32 digest1 = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        bytes32 digest2 = eigenOperator.calculateTotpDigestHash(address(0x123), address(eigenOperator));
        assertTrue(digest1 != digest2);
    }

    function test_totp_digest_changes_with_different_operator() public view {
        bytes32 digest1 = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        bytes32 digest2 = eigenOperator.calculateTotpDigestHash(restaker, address(0x123));
        assertTrue(digest1 != digest2);
    }

    // ============ SIGNATURE VALIDATION TESTS ============

    function test_signature_validation_with_allowlisted_digest() public {
        bytes32 digest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        bytes4 result = eigenOperator.isValidSignature(digest, "");

        /// This should return an invalid signature as we already used this once
        assertEq(result, bytes4(0xffffffff));

        vm.prank(restaker);
        eigenOperator.advanceTotp();
        digest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        result = eigenOperator.isValidSignature(digest, "");
        assertEq(result, bytes4(0x1626ba7e));
    }

    function test_signature_validation_with_non_allowlisted_digest() public view {
        bytes32 randomDigest = keccak256("random");
        bytes4 result = eigenOperator.isValidSignature(randomDigest, "");
        assertEq(result, bytes4(0xffffffff)); // Invalid signature
    }

    function test_signature_validation_after_totp_advance() public {
        bytes32 initialDigest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));

        // Advance TOTP
        vm.prank(restaker);
        eigenOperator.advanceTotp();

        // Both old and new digest should be valid
        assertEq(eigenOperator.isValidSignature(initialDigest, ""), bytes4(0x1626ba7e));

        bytes32 newDigest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        assertEq(eigenOperator.isValidSignature(newDigest, ""), bytes4(0x1626ba7e));
    }

    // ============ ACCESS CONTROL TESTS ============

    function test_register_operator_set_unauthorized() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        eigenOperator.registerOperatorSetToServiceManager(1, restaker);
    }

    function test_allocate_unauthorized() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        eigenOperator.allocate(1, eigenAb.eigenAddresses.strategy);
    }

    function test_update_metadata_unauthorized() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        eigenOperator.updateOperatorMetadataURI("new-metadata");
    }

    function test_update_metadata_authorized() public {
        vm.prank(operator);
        eigenOperator.updateOperatorMetadataURI("new-metadata");
        // No revert expected
    }

    function test_advance_totp_unauthorized() public {
        vm.expectRevert();
        eigenOperator.advanceTotp();
    }

    function test_advance_totp_authorized_after_registration() public {
        vm.prank(restaker);
        eigenOperator.advanceTotp();
        // No revert expected
    }

    // ============ ALLOCATION TESTS ============

    function test_allocate_already_allocated() public {
        // Wait a block
        vm.roll(block.number + 1);

        // Second allocation should revert
        vm.prank(serviceManager);
        vm.expectRevert();
        eigenOperator.allocate(1, eigenAb.eigenAddresses.strategy);
    }

    function test_allocate_without_registration() public {
        vm.prank(serviceManager);
        vm.expectRevert();
        eigenOperator.allocate(1, eigenAb.eigenAddresses.strategy);
    }

    // ============ REGISTRATION EDGE CASES ============

    function test_register_operator_set_multiple_times() public {
        // Second registration with different restaker should work (updates restaker)
        address newRestaker = address(0x456);
        vm.prank(serviceManager);
        vm.expectRevert();
        eigenOperator.registerOperatorSetToServiceManager(2, newRestaker);
    }

    function test_register_with_zero_restaker() public {
        vm.prank(serviceManager);
        vm.expectRevert();
        eigenOperator.registerOperatorSetToServiceManager(1, address(0));
    }

    // ============ TOTP EDGE CASES ============

    function test_totp_at_exact_period_boundary() public {
        uint256 periodStart = (block.timestamp / (28 days)) * (28 days);
        vm.warp(periodStart);

        uint256 totp1 = eigenOperator.currentTotp();
        uint256 expiry1 = eigenOperator.getCurrentTotpExpiryTimestamp();

        // Move to next period exactly
        vm.warp(periodStart + 28 days);

        uint256 totp2 = eigenOperator.currentTotp();
        uint256 expiry2 = eigenOperator.getCurrentTotpExpiryTimestamp();

        assertEq(totp2, totp1 + 1);
        assertEq(expiry2, expiry1 + 28 days);
    }

    function test_totp_with_zero_timestamp() public {
        vm.warp(0);

        uint256 totp = eigenOperator.currentTotp();
        uint256 expiry = eigenOperator.getCurrentTotpExpiryTimestamp();

        assertEq(totp, 0);
        assertEq(expiry, 28 days);
    }

    function test_totp_with_large_timestamp() public {
        uint256 largeTimestamp = type(uint256).max / 2; // Avoid overflow
        vm.warp(largeTimestamp);

        uint256 totp = eigenOperator.currentTotp();
        uint256 expectedTotp = largeTimestamp / (28 days);

        assertEq(totp, expectedTotp);
    }

    function test_multiple_totp_advances() public {
        bytes32 digest1 = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));

        // Advance multiple times
        vm.prank(restaker);
        eigenOperator.advanceTotp();

        vm.prank(restaker);
        eigenOperator.advanceTotp();

        vm.prank(restaker);
        eigenOperator.advanceTotp();

        // Original digest should still be valid
        assertEq(eigenOperator.isValidSignature(digest1, ""), bytes4(0x1626ba7e));

        // Current digest should also be valid
        bytes32 currentDigest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        assertEq(eigenOperator.isValidSignature(currentDigest, ""), bytes4(0x1626ba7e));
    }

    // ============ VIEW FUNCTION TESTS ============

    function test_view_functions_return_correct_values() public view {
        assertEq(eigenOperator.eigenServiceManager(), serviceManager);
        assertEq(eigenOperator.operator(), operator);
        assertEq(eigenOperator.restaker(), restaker);
    }

    // ============ COMPLEX INTEGRATION SCENARIOS ============

    function test_full_operator_lifecycle() public {
        // Verify digest is allowlisted
        bytes32 digest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));

        // used this digest already on test set up
        assertEq(eigenOperator.isValidSignature(digest, ""), bytes4(0xffffffff));

        // Wait a block and allocate
        vm.roll(block.number + 1);
        vm.prank(serviceManager);

        // We already allocated on test set up
        vm.expectRevert();
        eigenOperator.allocate(1, eigenAb.eigenAddresses.strategy);

        // Update metadata
        vm.prank(operator);
        eigenOperator.updateOperatorMetadataURI("updated-metadata");

        // Advance TOTP
        vm.prank(restaker);
        eigenOperator.advanceTotp();

        // Verify everything still works
        assertEq(eigenOperator.restaker(), restaker);
    }

    // ============ ERROR CONDITION TESTS ============

    function test_signature_validation_with_empty_signature() public view {
        bytes32 digest = keccak256("test");
        bytes4 result = eigenOperator.isValidSignature(digest, "");
        assertEq(result, bytes4(0xffffffff));
    }

    function test_signature_validation_with_long_signature() public view {
        bytes32 digest = keccak256("test");
        bytes memory longSig = new bytes(1000);
        bytes4 result = eigenOperator.isValidSignature(digest, longSig);
        assertEq(result, bytes4(0xffffffff));
    }

    function test_totp_calculation_consistency() public view {
        // Multiple calls should return same value in same block
        uint256 totp1 = eigenOperator.currentTotp();
        uint256 totp2 = eigenOperator.currentTotp();
        uint256 expiry1 = eigenOperator.getCurrentTotpExpiryTimestamp();
        uint256 expiry2 = eigenOperator.getCurrentTotpExpiryTimestamp();

        assertEq(totp1, totp2);
        assertEq(expiry1, expiry2);
    }

    // ============ STRESS TESTS ============

    function test_rapid_totp_advances() public {
        // Rapidly advance TOTP many times
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(restaker);
            eigenOperator.advanceTotp();
        }

        // Should still function correctly
        bytes32 digest = eigenOperator.calculateTotpDigestHash(restaker, address(eigenOperator));
        assertEq(eigenOperator.isValidSignature(digest, ""), bytes4(0x1626ba7e));
    }
}
