// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IcoSetup } from "./IcoSetup.sol";

contract SoulboundERC721MerkleTest is IcoSetup {
    address public recipient;
    bytes32[] public proofs;

    function setUp() public override {
        super.setUp();

        recipient = 0x815f5BB257e88b67216a344C7C83a3eA4EE74748;
        proofs = new bytes32[](14);
        proofs[0] = bytes32(0xe8e039d64c641a82c044042612ca920a8777a1c454e5858e703c44105ce94179);
        proofs[1] = bytes32(0x0acc6722d5fc3f8e81be5da53eda26522102a56a7d3795bd82f4214d0254b742);
        proofs[2] = bytes32(0x691dff85343fc17606046c76418dc548ddf47094233c907a7977307b5fe7a513);
        proofs[3] = bytes32(0xb3ed2e9854ff3376170388333df9d6f45b32255f5eec2f7443ba2522fbedf625);
        proofs[4] = bytes32(0x10cdeff5852b8d023f5b02b7a6759ab728a085b39fdf1473380ce3b22e9a4018);
        proofs[5] = bytes32(0xc48bda43d35eb36ba0bd757de85c0ef705548f0ccb40ab4ac5a888bc7903393a);
        proofs[6] = bytes32(0x5c088a2c9b367b1085515cddbd656750a6c55d453fb2e21013f67cbbd850d19a);
        proofs[7] = bytes32(0x4a1f4406451c642fe4b91127fc381b3bd555615063779423be3825eb459caa9e);
        proofs[8] = bytes32(0xc035784032cf84cde9276f5e60e6f6045134a5c1ab9ba984303a7ef67f8ea529);
        proofs[9] = bytes32(0x9615df8885f4c0f26ca28fb23f122366a1b439aab816dadfaf520b63d8f72750);
        proofs[10] = bytes32(0x30fb5af36a5fd0c676715b628fe1ba932beef488b3e5da55b7c0f8aa6bc3ce02);
        proofs[11] = bytes32(0xa44cfbe18321905148110005eed16e2ab95fe54b742db8418691640accdb89af);
        proofs[12] = bytes32(0xbfcc3d8154e486877a1e92b9b8404d51ff73881e884d26a0417c8d87d1303e05);
        proofs[13] = bytes32(0xfa522b5f5a2fa8dbcd97ba29a398a575d4775602cde1190ee615baba1a2015d1);
    }

    function test_soulbound_erc721_owner_mint() public {
        address[] memory recipients = new address[](2);
        recipients[0] = admin;
        recipients[1] = user;

        vm.startPrank(user);
        vm.expectRevert(); // Only owner can mint
        erc721.ownerMint(recipients);

        vm.startPrank(admin);
        erc721.ownerMint(recipients);
        assertEq(erc721.balanceOf(admin), 1);
        assertEq(erc721.balanceOf(user), 1);

        vm.expectRevert(); // Only one mint per address
        erc721.ownerMint(recipients);
    }

    function test_soulbound_erc721_mint() public {
        vm.startPrank(user);

        vm.expectRevert(); // Minting is not unpaused
        erc721.mint(recipient, proofs);

        vm.startPrank(admin);
        erc721.unpause();

        vm.startPrank(user);
        erc721.mint(recipient, proofs);
        assertEq(erc721.balanceOf(recipient), 1);

        vm.expectRevert(); // Only one mint per address
        erc721.mint(recipient, proofs);
    }

    function test_soulbound_erc721_mint_wrong_proof() public {
        // first proof is wrong
        proofs[0] = bytes32(0x0d2f248c0da803bb3220242883533fb09e2c965a100a3fe656e7b7849871175c);

        vm.startPrank(admin);
        erc721.unpause();

        vm.startPrank(user);
        vm.expectRevert(); // Invalid proof
        erc721.mint(recipient, proofs);
    }

    function test_soulbound_erc721_transfer() public {
        vm.startPrank(admin);
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        erc721.ownerMint(recipients);
        assertEq(erc721.balanceOf(user), 1);

        vm.startPrank(user);
        vm.expectRevert(); // Soulbound
        erc721.transferFrom(user, admin, 0);

        vm.expectRevert(); // Invalid recipient
        erc721.transferFrom(user, address(0), 0);

        vm.expectRevert(); // Invalid owner
        erc721.transferFrom(admin, user, 0);

        vm.expectRevert(); // Transfer to any address, including self, is not allowed
        erc721.transferFrom(user, user, 0);
    }
}
