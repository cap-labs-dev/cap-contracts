// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IValidationHook } from "../../contracts/interfaces/IValidationHook.sol";
import { IcoSetup } from "./IcoSetup.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IPredicateClient } from "@predicate/interfaces/IPredicateClient.sol";

contract ValidationHookTest is IcoSetup {
    function setUp() public override {
        super.setUp();
    }

    function test_validation_hook_supports_interface() public {
        assertEq(validationHook.supportsInterface(type(IValidationHook).interfaceId), true);
        assertEq(validationHook.supportsInterface(type(IPredicateClient).interfaceId), true);
        assertEq(validationHook.supportsInterface(type(IERC165).interfaceId), true);
    }
}
