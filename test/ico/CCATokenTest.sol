// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MockERC20 } from "../mocks/MockERC20.sol";
import { IcoSetup } from "./IcoSetup.sol";

contract CCATokenTest is IcoSetup {
    MockERC20 public asset;

    function setUp() public override {
        super.setUp();

        asset = new MockERC20("Asset", "ASSET", 18);
    }

    function test_cca_token_owner_mint() public {
        vm.startPrank(user);
        vm.expectRevert(); // Only owner can mint
        ccaToken.mint(user, 1000);

        vm.startPrank(admin);
        ccaToken.mint(user, 1000);
        assertEq(ccaToken.balanceOf(user), 1000);
    }

    function test_cca_token_transfer() public {
        vm.startPrank(admin);
        ccaToken.mint(admin, 1000);
        assertEq(ccaToken.balanceOf(admin), 1000);

        vm.expectRevert(); // Soulbound unless sender is whitelisted
        ccaToken.transfer(admin, 500);

        ccaToken.setWhitelist(admin, true);
        ccaToken.transfer(user, 500);
        assertEq(ccaToken.balanceOf(admin), 500);
        assertEq(ccaToken.balanceOf(user), 500);

        vm.expectRevert(); // Transfer to zero address is not allowed
        ccaToken.transfer(address(0), 500);

        vm.startPrank(user);
        vm.expectRevert(); // Soulbound unless sender is whitelisted or zap
        ccaToken.transfer(admin, 500);

        // simulate zap pulling tokens from user via token manager
        address tokenManager = address(zapRouter.zapTokenManager());
        ccaToken.approve(tokenManager, 500);
        vm.startPrank(tokenManager);
        ccaToken.transferFrom(address(user), address(zapRouter), 500); // zap is allowed to receive CCA tokens, even if sender is not whitelisted
    }

    function test_cca_token_exchange() public {
        vm.startPrank(admin);
        ccaToken.setAsset(address(asset));
        ccaToken.mint(user, 1_000);

        // simulate asset being transferred to cca token contract
        asset.mint(address(ccaToken), 10_000);

        vm.startPrank(user);
        vm.expectRevert(); // Not unpaused
        ccaToken.exchange(user);

        vm.startPrank(admin);
        ccaToken.unpause();

        vm.startPrank(user);
        ccaToken.exchange(user);
        assertEq(ccaToken.balanceOf(user), 0);
        assertEq(asset.balanceOf(user), 1_000);

        vm.startPrank(admin);
        ccaToken.mint(user, 1_000);

        vm.expectRevert(); // Not approved by user
        ccaToken.exchangeFrom(user, user);

        vm.startPrank(user);
        ccaToken.approve(admin, 1_000);

        vm.startPrank(admin);
        ccaToken.exchangeFrom(user, user);
        assertEq(ccaToken.balanceOf(user), 0);
        assertEq(asset.balanceOf(user), 2_000);

        ccaToken.mint(user, 10_000); // simulate user exchanging more CCA tokens than the asset balance
        vm.startPrank(user);
        vm.expectRevert(); // Insufficient balance
        ccaToken.exchange(user);

        asset.mint(address(ccaToken), 2_000); // match the asset balance with the CCA tokens
        // simulate zap exchanging tokens for user
        vm.startPrank(user);
        address tokenManager = address(zapRouter.zapTokenManager());
        ccaToken.approve(tokenManager, 10_000);
        vm.startPrank(tokenManager);
        ccaToken.transferFrom(address(user), address(zapRouter), 10_000);
        vm.startPrank(address(zapRouter));
        ccaToken.exchange(user);
        assertEq(ccaToken.balanceOf(address(zapRouter)), 0);
        assertEq(asset.balanceOf(user), 12_000);
    }
}
