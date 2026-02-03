// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { Stabledrop } from "../../contracts/ico/Stabledrop.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { Test } from "forge-std/Test.sol";

contract StabledropTest is Test {
    MockERC20 public token;
    Stabledrop public stabledrop;
    AccessControl public accessControl;
    address public admin;
    address public user;
    bytes32[] public proofs;

    function setUp() public virtual {
        admin = makeAddr("admin");
        vm.deal(admin, 1 ether);
        user = address(0x1111111111111111111111111111111111111111);
        vm.deal(user, 1 ether);

        proofs = new bytes32[](2);
        proofs[0] = bytes32(0xb92c48e9d7abe27fd8dfd6b5dfdbfb1c9a463f80c712b66f3a5180a090cccafc);
        proofs[1] = bytes32(0xf8330a2c877270873c192c2bc9468a45f87284fcf68ef5c8aeed39a26721e6eb);

        accessControl = AccessControl(
            address(
                new ERC1967Proxy(
                    address(new AccessControl()), abi.encodeWithSelector(AccessControl.initialize.selector, admin)
                )
            )
        );

        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(admin, 1000e18);

        stabledrop = Stabledrop(
            address(
                new ERC1967Proxy(
                    address(new Stabledrop()),
                    abi.encodeWithSelector(
                        Stabledrop.initialize.selector,
                        address(accessControl),
                        bytes32(0x25d9bd74a87ae3eccc3d577a4d621c0bc328a17cd988b85adad34a660d7fa439),
                        address(token)
                    )
                )
            )
        );

        vm.startPrank(admin);
        accessControl.grantAccess(stabledrop.setRoot.selector, address(stabledrop), admin);
        accessControl.grantAccess(stabledrop.recoverERC20.selector, address(stabledrop), admin);
        accessControl.grantAccess(stabledrop.pause.selector, address(stabledrop), admin);
        accessControl.grantAccess(stabledrop.unpause.selector, address(stabledrop), admin);
        accessControl.grantAccess(stabledrop.approveOperatorFor.selector, address(stabledrop), admin);

        token.approve(address(stabledrop), 1000e18);
        stabledrop.fund(1000e18);
        stabledrop.unpause();
    }

    function test_claim() public {
        vm.startPrank(user);
        stabledrop.claim(user, user, 1e18, proofs);
        assertEq(token.balanceOf(user), 1e18);
        assertEq(stabledrop.totalClaimed(), 1e18);
        assertEq(stabledrop.claimed(user), 1e18);
    }

    function test_claim_for_another_user() public {
        vm.startPrank(user);
        stabledrop.approveOperator(admin, true);
        vm.startPrank(admin);
        stabledrop.claim(user, user, 1e18, proofs);
        assertEq(token.balanceOf(user), 1e18);
        assertEq(stabledrop.totalClaimed(), 1e18);
        assertEq(stabledrop.claimed(user), 1e18);
    }

    function test_claim_reverts_when_invalid_proof() public {
        vm.startPrank(user);
        vm.expectRevert();
        stabledrop.claim(user, user, 1e18, new bytes32[](0));
    }

    function test_double_claim_reverts() public {
        vm.startPrank(user);
        stabledrop.claim(user, user, 1e18, proofs);
        assertEq(token.balanceOf(user), 1e18);
        assertEq(stabledrop.totalClaimed(), 1e18);
        assertEq(stabledrop.claimed(user), 1e18);
        vm.expectRevert();
        stabledrop.claim(user, user, 1e18, proofs);
    }

    function test_claim_reverts_when_insufficient_balance() public {
        vm.startPrank(admin);
        stabledrop.recoverERC20(address(token), admin, 1000e18);
        vm.startPrank(user);
        vm.expectRevert();
        stabledrop.claim(user, user, 1e18, proofs);
    }

    function test_claim_during_pause_reverts() public {
        vm.startPrank(admin);
        stabledrop.pause();
        vm.startPrank(user);
        vm.expectRevert();
        stabledrop.claim(user, user, 1e18, proofs);
    }

    function test_update_root() public {
        vm.startPrank(user);
        stabledrop.claim(user, user, 1e18, proofs);
        assertEq(token.balanceOf(user), 1e18);
        assertEq(stabledrop.totalClaimed(), 1e18);
        assertEq(stabledrop.claimed(user), 1e18);

        vm.startPrank(admin);
        stabledrop.setRoot(bytes32(0xc8bdf0d32cf49216e6843e3867120be5dbda37a3aceaf720548b7ee5b41c458c));
        vm.startPrank(user);
        stabledrop.claim(user, user, 1.1e18, proofs);
        assertEq(token.balanceOf(user), 1.1e18);
        assertEq(stabledrop.totalClaimed(), 1.1e18);
        assertEq(stabledrop.claimed(user), 1.1e18);
    }
}
