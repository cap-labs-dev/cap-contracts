// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC7540Operator } from "../../../contracts/ERC7540/ERC7540Operator.sol";
import { Test } from "forge-std/Test.sol";

contract ERC7540OperatorTest is Test {
    ERC7540Operator internal op;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setUp() public {
        op = new ERC7540Operator();
    }

    function test_defaultIsNotOperator() public view {
        assertFalse(op.isOperator(alice, bob));
    }

    function test_setOperator_setsAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit OperatorSet(alice, bob, true);
        vm.prank(alice);
        bool ok = op.setOperator(bob, true);
        assertTrue(ok);
        assertTrue(op.isOperator(alice, bob));
    }

    function test_setOperator_revoke() public {
        vm.prank(alice);
        op.setOperator(bob, true);
        vm.prank(alice);
        op.setOperator(bob, false);
        assertFalse(op.isOperator(alice, bob));
    }

    function test_operatorIsDirectional() public {
        vm.prank(alice);
        op.setOperator(bob, true);
        // alice approved bob, not the reverse
        assertTrue(op.isOperator(alice, bob));
        assertFalse(op.isOperator(bob, alice));
    }
}
