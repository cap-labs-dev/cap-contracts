// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { Statement } from "@predicate/interfaces/IPredicateRegistry.sol";

// Mock PredicateRegistry for testing
contract MockPredicateRegistry {
    function validateAttestation(Statement calldata, Attestation calldata) external pure returns (bool isVerified) {
        isVerified = true;
    }

    function setPolicyID(string memory _policyID) external {
        // Do nothing
    }
}
