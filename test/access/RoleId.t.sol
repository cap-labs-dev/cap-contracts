// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { RoleId } from "../../contracts/access/RoleId.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract RoleIdTest is Test {
    address public mockContractAddress;
    bytes4 public constant MOCK_SELECTOR = bytes4(keccak256("mockFunction()"));
    bytes4 public constant ANOTHER_SELECTOR = bytes4(keccak256("anotherFunction()"));

    function setUp() public {
        mockContractAddress = address(0x123);
    }

    function test_roleId_encoding_decoding() public view {
        // Test basic encoding
        bytes32 roleId = RoleId.roleId(MOCK_SELECTOR, mockContractAddress);
        bytes32 expected = bytes32(MOCK_SELECTOR) | bytes32(uint256(uint160(mockContractAddress)));
        assertEq(roleId, expected, "Role ID should be generated correctly");

        // Test decoding
        (bytes4 selector, address contractAddress) = RoleId.decodeRoleId(roleId);
        assertEq(selector, MOCK_SELECTOR, "Decoded selector should match original");
        assertEq(contractAddress, mockContractAddress, "Decoded contract address should match original");

        // Test round-trip functionality
        bytes32 regeneratedRoleId = RoleId.roleId(selector, contractAddress);
        assertEq(roleId, regeneratedRoleId, "Round-trip encoding/decoding should match");
    }

    function test_roleId_uniqueness() public view {
        bytes32 roleId1 = RoleId.roleId(MOCK_SELECTOR, mockContractAddress);

        // Different selector, same address
        bytes32 roleId2 = RoleId.roleId(ANOTHER_SELECTOR, mockContractAddress);
        assertTrue(roleId1 != roleId2, "Role IDs should be unique for different selectors");

        // Same selector, different address
        address otherAddress = address(0x456);
        bytes32 roleId3 = RoleId.roleId(MOCK_SELECTOR, otherAddress);
        assertTrue(roleId1 != roleId3, "Role IDs should be unique for different addresses");
    }

    function test_roleId_edgeCases() public view {
        // Zero address
        address zeroAddress = address(0);
        bytes32 roleId1 = RoleId.roleId(MOCK_SELECTOR, zeroAddress);
        (bytes4 selector1, address addr1) = RoleId.decodeRoleId(roleId1);
        assertEq(selector1, MOCK_SELECTOR, "Decoded selector should match with zero address");

        // Zero selector
        bytes4 zeroSelector = bytes4(0);
        bytes32 roleId2 = RoleId.roleId(zeroSelector, mockContractAddress);
        (bytes4 selector2, address addr2) = RoleId.decodeRoleId(roleId2);
        assertEq(selector2, zeroSelector, "Decoded selector should be zero");

        // Both encoding/decoding should be reversible
        bytes32 regenerated1 = RoleId.roleId(selector1, addr1);
        bytes32 regenerated2 = RoleId.roleId(selector2, addr2);
        assertEq(roleId1, regenerated1, "Zero address round-trip should match");
        assertEq(roleId2, regenerated2, "Zero selector round-trip should match");

        // Max bytes4 value (0xffffffff)
        bytes4 maxSelector = bytes4(type(uint32).max);
        bytes32 roleId3 = RoleId.roleId(maxSelector, mockContractAddress);
        (bytes4 selector3, address addr3) = RoleId.decodeRoleId(roleId3);
        assertEq(selector3, maxSelector, "Decoded selector should match max selector");

        // Max address value (0xffffffffffffffffffffffffffffffffffffffff)
        address maxAddress = address(type(uint160).max);
        bytes32 roleId4 = RoleId.roleId(MOCK_SELECTOR, maxAddress);
        (bytes4 selector4, address addr4) = RoleId.decodeRoleId(roleId4);
        assertEq(selector4, MOCK_SELECTOR, "Decoded selector should match with max address");

        // Test round-trip with max values
        bytes32 regenerated3 = RoleId.roleId(selector3, addr3);
        bytes32 regenerated4 = RoleId.roleId(selector4, addr4);
        assertEq(roleId3, regenerated3, "Max selector round-trip should match");
        assertEq(roleId4, regenerated4, "Max address round-trip should match");

        // Both max values
        bytes32 roleId5 = RoleId.roleId(maxSelector, maxAddress);
        (bytes4 selector5, address addr5) = RoleId.decodeRoleId(roleId5);
        assertEq(selector5, maxSelector, "Decoded max selector should match");
        assertEq(addr5, maxAddress, "Decoded max address should match");
        bytes32 regenerated5 = RoleId.roleId(selector5, addr5);
        assertEq(roleId5, regenerated5, "Round-trip with both max values should match");
    }
}
