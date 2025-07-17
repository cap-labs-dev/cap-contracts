// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IDelegatorHook } from "@symbioticfi/core/src/interfaces/delegator/IDelegatorHook.sol";

interface IOperatorNetworkSpecificDecreaseHook is IDelegatorHook {
    error NotOperatorNetworkSpecificDelegator();

    /**
     * @notice Called when an operator is slashed
     * @param subnetwork The subnetwork identifier
     * @param operator The operator address
     * @param slashedAmount The amount slashed
     * @param captureTimestamp The timestamp of the capture
     * @param data Additional data
     */
    function onSlash(
        bytes32 subnetwork,
        address operator,
        uint256 slashedAmount,
        uint48 captureTimestamp,
        bytes calldata data
    ) external;
}
