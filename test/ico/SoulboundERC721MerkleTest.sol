// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IcoSetup } from "./IcoSetup.sol";

contract SoulboundERC721MerkleTest is IcoSetup {
    address public recipient;
    bytes32[] public proofs;

    function setUp() public override {
        super.setUp();

        recipient = 0x23d0f8944468F79FB06850c136a0E6B3Ee4a450F;
        proofs = new bytes32[](15);
        proofs[0] = bytes32(0x3d2f248c0da803bb3220242883533fb09e2c965a100a3fe656e7b7849871175c);
        proofs[1] = bytes32(0x61d0c3d954ddad08ffd9b454ab7fca1b70fac9b5b6fd62f3904b53bacaeeb908);
        proofs[2] = bytes32(0x8936f87a56934008dd248074790ee7ec02bf94b1c98b7b7fca2aa135700029b7);
        proofs[3] = bytes32(0x4e9d5e84445460da1d80a6fe64f9b1a835f9bc810a2f20ee04722fe7ee792e62);
        proofs[4] = bytes32(0x483349a1b6197a09050553d284931fc10fd6709407dbf95ae10db90fe5192e5f);
        proofs[5] = bytes32(0x7dfcca1043d6ac54e21de746da6dd486c768048401e828470cfc3b9acf0d9541);
        proofs[6] = bytes32(0x5d65ba18b54ebf7ca135d686c638938eb8cf5df15fef1278b3054e1f397a71c8);
        proofs[7] = bytes32(0x4185773ee38f75af360fef7693f902ab8725159f797430a118b39307413ec51e);
        proofs[8] = bytes32(0x13bf537badcf896c81aa9f293cf3ee09075e601e2b8bcf8a568d5aa3a1c66ba9);
        proofs[9] = bytes32(0xe79323be115eac08b2114a6f512db7bb95458a9d749139d2de6a336975977ccd);
        proofs[10] = bytes32(0x1d7c3d3bc3ee70a4e1f6450706ec576962cffcbea57b5f32e55b64c5df7e5a29);
        proofs[11] = bytes32(0x9e7760200a4302d98d10c314c4f6dade611d66137afb3d4acc5739e3cc1c99f4);
        proofs[12] = bytes32(0x51dd39f225eab883378a14a429ba5b502f11fa9159bb3753f6bc489f85d5bbce);
        proofs[13] = bytes32(0x502cd90d7171bfeb1db55e8ece299e3d75fdd5de91d249f37ef3db7db273294e);
        proofs[14] = bytes32(0xb9189d76b22a31f2bf5586adc5c10223281ce677b77d074ca005b290d7d367ff);
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
        // first digit of proof is wrong
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
