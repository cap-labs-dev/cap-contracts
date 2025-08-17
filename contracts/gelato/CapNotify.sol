// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ICapNotify } from "../interfaces/ICapNotify.sol";

import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";
import { IStakedCap } from "../interfaces/IStakedCap.sol";

import { CapNotifyStorageUtils } from "../storage/CapNotifyStorageUtils.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Cap Notifier
/// @author weso, Cap Labs
/// @notice Calls distribute from the Fee Receiver contract
contract CapNotify is ICapNotify, CapNotifyStorageUtils, Initializable {
    /// @inheritdoc ICapNotify
    function initialize(address _feeReceiver, address _stakedCap) external initializer {
        CapNotifyStorage storage $ = getCapNotifyStorage();
        $.feeReceiver = _feeReceiver;
        $.stakedCap = _stakedCap;
    }

    /// @inheritdoc ICapNotify
    function notify() external {
        CapNotifyStorage storage $ = getCapNotifyStorage();
        IFeeReceiver($.feeReceiver).distribute();
    }

    /// @inheritdoc ICapNotify
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        CapNotifyStorage storage $ = getCapNotifyStorage();
        uint256 lastNotify = IStakedCap($.stakedCap).lastNotify();
        uint256 duration = IStakedCap($.stakedCap).lockDuration();
        if (lastNotify + duration > block.timestamp) return (false, bytes("Not time to notify"));

        return (true, abi.encodeCall(this.notify, ()));
    }
}
