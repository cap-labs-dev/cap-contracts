// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";

library SymbioticSubnetworkLib {
    /// @notice Get the subnetwork for a vault
    /// @dev create one subnetwork per vault this, in combination with the NetworkRestakeDelegator, ensures that
    /// we cannot delegate the same backing asset twice
    /// @param vault Vault address
    /// @param network Network address
    /// @return subnetwork Subnetwork
    function vaultSubnetwork(address vault, address network) internal pure returns (bytes32) {
        uint96 identifier = uint96(uint256(keccak256(abi.encodePacked(vault))));
        return Subnetwork.subnetwork(network, identifier);
    }
}
