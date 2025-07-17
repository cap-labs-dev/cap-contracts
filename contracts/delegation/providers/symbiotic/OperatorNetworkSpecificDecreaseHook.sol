// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOperatorNetworkSpecificDecreaseHook } from "../../../interfaces/IOperatorNetworkSpecificDecreaseHook.sol";

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IDelegatorHook } from "@symbioticfi/core/src/interfaces/delegator/IDelegatorHook.sol";
import { IOperatorNetworkSpecificDelegator } from
    "@symbioticfi/core/src/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperatorNetworkSpecificDecreaseHook is IOperatorNetworkSpecificDecreaseHook {
    using Math for uint256;
    using Subnetwork for bytes32;

    /**
     * @inheritdoc IOperatorNetworkSpecificDecreaseHook
     */
    function onSlash(
        bytes32 subnetwork,
        address, /* operator */
        uint256 slashedAmount,
        uint48, /* captureTimestamp */
        bytes calldata /* data */
    ) external {
        if (IEntity(msg.sender).TYPE() != 3) {
            revert NotOperatorNetworkSpecificDelegator();
        }

        if (slashedAmount == 0) {
            return;
        }

        uint256 networkLimit = IOperatorNetworkSpecificDelegator(msg.sender).maxNetworkLimit(subnetwork);
        if (networkLimit != 0) {
            IOperatorNetworkSpecificDelegator(msg.sender).setMaxNetworkLimit(
                subnetwork.identifier(), networkLimit - Math.min(slashedAmount, networkLimit)
            );
        }
    }
}
