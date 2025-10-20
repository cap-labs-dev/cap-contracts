// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Wrapper } from "../../contracts/token/Wrapper.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockPermissionedERC20 } from "../mocks/MockPermissionedERC20.sol";

contract WrapperTest is TestDeployer {
    MockPermissionedERC20 permissionedAsset;
    Wrapper wrapper;
    address user;
    address user2;

    function setUp() public {
        _deployCapTestEnvironment();

        permissionedAsset = MockPermissionedERC20(env.permissionedMocks[0]);
        wrapper = Wrapper(env.permissionedMocks[1]);
        user = makeAddr("user");
        user2 = makeAddr("user2");

        permissionedAsset.whitelist(user);
        permissionedAsset.whitelist(user2);
        permissionedAsset.whitelist(address(wrapper));
    }

    function test_wrapper_mint() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        assertEq(wrapper.balanceOf(user), 100e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 100e18);
        assertEq(permissionedAsset.balanceOf(user), 0);

        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user2, 100e18);

        assertEq(wrapper.balanceOf(user), 100e18);
        assertEq(wrapper.balanceOf(user2), 100e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 200e18);
        assertEq(permissionedAsset.balanceOf(user), 0);
        assertEq(permissionedAsset.balanceOf(user2), 0);
    }

    function test_wrapper_withdraw() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        assertEq(wrapper.balanceOf(user), 100e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 100e18);
        assertEq(permissionedAsset.balanceOf(user), 0);

        wrapper.withdrawTo(user, 50e18);

        assertEq(wrapper.balanceOf(user), 50e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 50e18);
        assertEq(permissionedAsset.balanceOf(user), 50e18);

        wrapper.withdrawTo(user2, 50e18);

        assertEq(permissionedAsset.balanceOf(address(wrapper)), 0);
        assertEq(permissionedAsset.balanceOf(user2), 50e18);
        assertEq(permissionedAsset.balanceOf(user), 50e18);
    }

    function test_wrapper_withdraw_to_blacklisted_address() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        assertEq(wrapper.balanceOf(user), 100e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 100e18);
        assertEq(permissionedAsset.balanceOf(user), 0);

        permissionedAsset.blacklist(user);

        // Should revert because user is not whitelisted
        vm.expectRevert(MockPermissionedERC20.NotWhitelisted.selector);
        wrapper.withdrawTo(user, 50e18);

        // Should succeed because user2 is whitelisted
        wrapper.withdrawTo(user2, 50e18);

        assertEq(wrapper.balanceOf(user), 50e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 50e18);
        assertEq(permissionedAsset.balanceOf(user2), 50e18);
        assertEq(permissionedAsset.balanceOf(user), 0);
    }

    function test_transfer_wrapper_to_blacklisted_address() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        permissionedAsset.blacklist(user2);

        wrapper.transfer(user2, 50e18);

        // Withdrawals should revert because user2 is not whitelisted
        vm.startPrank(user2);
        vm.expectRevert(MockPermissionedERC20.NotWhitelisted.selector);
        wrapper.withdrawTo(user2, 50e18);

        // Wrapper transfers are not affected by blacklisting
        wrapper.transfer(user, 50e18);

        vm.startPrank(user);

        wrapper.withdrawTo(user, 50e18);

        assertEq(wrapper.balanceOf(user), 50e18);
        assertEq(wrapper.balanceOf(user2), 0);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 50e18);
        assertEq(permissionedAsset.balanceOf(user), 50e18);
        assertEq(permissionedAsset.balanceOf(user2), 0);
    }

    function test_skim() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        permissionedAsset.mint(address(wrapper), 100e18);

        assertEq(wrapper.skimmable(), 100e18);

        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());

        assertEq(wrapper.balanceOf(address(wrapper.donationReceiver())), 100e18);
    }

    function test_wrapper_as_deposit_recipient() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);

        vm.expectRevert();
        wrapper.depositFor(address(wrapper), 100e18);
    }

    function test_wrapper_as_withdrawal_recipient() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.expectRevert();
        wrapper.withdrawTo(address(wrapper), 100e18);
    }

    function test_one_wei_deposit_and_withdraw() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 1);
        permissionedAsset.approve(address(wrapper), 1);
        wrapper.depositFor(user, 1);

        assertEq(wrapper.balanceOf(user), 1);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 1);
        assertEq(permissionedAsset.balanceOf(user), 0);

        wrapper.withdrawTo(user, 1);

        assertEq(wrapper.balanceOf(user), 0);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 0);
        assertEq(permissionedAsset.balanceOf(user), 1);
    }

    function test_zero_amount_deposit_and_withdraw() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.startPrank(user2);

        wrapper.depositFor(user2, 0);

        assertEq(wrapper.balanceOf(user2), 0);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 100e18);
        assertEq(permissionedAsset.balanceOf(user2), 0);

        vm.startPrank(user);

        wrapper.withdrawTo(user, 0);

        assertEq(wrapper.balanceOf(user), 100e18);
        assertEq(permissionedAsset.balanceOf(address(wrapper)), 100e18);
        assertEq(permissionedAsset.balanceOf(user), 0);
    }

    function test_deposit_to_zero_address() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);

        vm.expectRevert();
        wrapper.depositFor(address(0), 100e18);
    }

    function test_withdraw_to_zero_address() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.expectRevert();
        wrapper.withdrawTo(address(0), 100e18);
    }

    function test_skim_zero_amount() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        assertEq(wrapper.skimmable(), 0);

        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());
        assertEq(permissionedAsset.balanceOf(address(wrapper.donationReceiver())), 0);
    }

    function test_skim_twice() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        permissionedAsset.mint(address(wrapper), 100e18);

        assertEq(wrapper.skimmable(), 100e18);

        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());
        assertEq(wrapper.balanceOf(address(wrapper.donationReceiver())), 100e18);
        assertEq(wrapper.skimmable(), 0);

        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());
        assertEq(wrapper.balanceOf(address(wrapper.donationReceiver())), 100e18);
    }

    function test_transfer_wrapper_without_sufficient_balance() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.expectRevert();
        wrapper.transfer(user2, 101e18);
    }

    function test_transfer_wrapper_to_zero_address() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.expectRevert();
        wrapper.transfer(address(0), 100e18);
    }

    function test_set_donation_receiver() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        permissionedAsset.mint(address(wrapper), 100e18);
        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());
        assertEq(wrapper.balanceOf(address(wrapper.donationReceiver())), 100e18);

        _grantAccess(wrapper.setDonationReceiver.selector, address(wrapper), env.users.access_control_admin);
        vm.startPrank(env.users.access_control_admin);
        address newDonationReceiver = makeAddr("newDonationReceiver");

        wrapper.setDonationReceiver(newDonationReceiver);

        assertEq(wrapper.donationReceiver(), newDonationReceiver);

        permissionedAsset.mint(address(wrapper), 100e18);
        wrapper.skim();

        assertEq(permissionedAsset.balanceOf(address(wrapper)), wrapper.totalSupply());
        assertEq(wrapper.balanceOf(newDonationReceiver), 100e18);
    }

    function test_set_donation_receiver_to_zero_address() public {
        _grantAccess(wrapper.setDonationReceiver.selector, address(wrapper), env.users.access_control_admin);
        vm.startPrank(env.users.access_control_admin);

        vm.expectRevert();
        wrapper.setDonationReceiver(address(0));
    }

    function test_withdraw_more_than_balance() public {
        vm.startPrank(user);
        permissionedAsset.mint(user, 100e18);
        permissionedAsset.approve(address(wrapper), 100e18);
        wrapper.depositFor(user, 100e18);

        vm.expectRevert();
        wrapper.withdrawTo(user, 101e18);
    }
}
