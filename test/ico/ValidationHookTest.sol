// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IValidationHook } from "../../contracts/interfaces/IValidationHook.sol";
import { IcoSetup } from "./IcoSetup.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IPredicateClient } from "@predicate/interfaces/IPredicateClient.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

contract ValidationHookTest is IcoSetup {
    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        erc721.ownerMint(recipients);
    }

    function test_validation_hook_supports_interface() public {
        assertEq(validationHook.supportsInterface(type(IValidationHook).interfaceId), true);
        assertEq(validationHook.supportsInterface(type(IPredicateClient).interfaceId), true);
        assertEq(validationHook.supportsInterface(type(IERC165).interfaceId), true);
    }

    function test_validation_hook_validate() public {
        vm.startPrank(auction);
        Attestation memory attestation =
            Attestation({ uuid: "123", expiration: 0, attester: address(0), signature: hex"" });
        validationHook.validate(1000, 1000, user, user, abi.encode(attestation));

        vm.expectRevert(); // Sender and owner must be the same
        validationHook.validate(1000, 1000, admin, user, abi.encode(attestation));

        vm.startPrank(user);
        vm.expectRevert(); // Only auction can call validate
        validationHook.validate(1000, 1000, user, user, abi.encode(attestation));

        vm.startPrank(auction);
        vm.expectRevert(); // User must own the ERC721 token
        validationHook.validate(1000, 1000, admin, admin, abi.encode(attestation));

        vm.roll(block.number + 2000); // block gate has passed, ERC721 ownership is not required
        validationHook.validate(1000, 1000, admin, admin, abi.encode(attestation));
    }
}
