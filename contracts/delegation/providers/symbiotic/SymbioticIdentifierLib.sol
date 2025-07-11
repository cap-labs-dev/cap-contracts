// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";

library SymbioticIdentifierLib {
    /// @dev Get subnetwork identifier
    /// @param _agent Agent address
    /// @return id Subnetwork identifier
    function subnetworkIdentifier(address _agent) public pure returns (uint96 id) {
        bytes32 hash = keccak256(abi.encodePacked(_agent));
        id = uint96(uint256(hash)); // Takes first 96 bits of hash
    }

    function subnetwork(address _agent, address _network) public pure returns (bytes32 id) {
        id = Subnetwork.subnetwork(_network, subnetworkIdentifier(_agent));
    }
}
