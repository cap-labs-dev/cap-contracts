// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOperatorSpecificDecreaseHook } from
    "@symbioticfi/hooks/src/interfaces/operatorSpecificDelegator/IOperatorSpecificDecreaseHook.sol";

import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IDelegatorHook } from "@symbioticfi/core/src/interfaces/delegator/IDelegatorHook.sol";
import { IOperatorSpecificDelegator } from "@symbioticfi/core/src/interfaces/delegator/IOperatorSpecificDelegator.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev same as @symbioticfi/hooks/src/contracts/operatorSpecificDelegator/OperatorSpecificDecreaseHook.sol
 *      but using solidity 0.8.28
 */
contract OperatorSpecificDecreaseHook is IOperatorSpecificDecreaseHook {
    using Math for uint256;

    /**
     * @inheritdoc IDelegatorHook
     */
    function onSlash(
        bytes32 subnetwork,
        address, /* operator */
        uint256 slashedAmount,
        uint48, /* captureTimestamp */
        bytes calldata /* data */
    ) external {
        if (IEntity(msg.sender).TYPE() != 2) {
            revert NotOperatorSpecificDelegator();
        }

        if (slashedAmount == 0) {
            return;
        }

        uint256 networkLimit = IOperatorSpecificDelegator(msg.sender).networkLimit(subnetwork);
        if (networkLimit != 0) {
            IOperatorSpecificDelegator(msg.sender).setNetworkLimit(
                subnetwork, networkLimit - Math.min(slashedAmount, networkLimit)
            );
        }
    }
}
