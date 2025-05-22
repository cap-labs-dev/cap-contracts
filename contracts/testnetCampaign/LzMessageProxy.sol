// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {
    MessagingFee,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title LzMessageProxy
/// @notice Proxy for LayerZero messages to other endpoints
contract LzMessageProxy is OApp {
    using EnumerableSet for EnumerableSet.UintSet;
    using OptionsBuilder for bytes;

    /// @dev Gas limit for the LayerZero bridge
    uint128 public lzReceiveGas = 100_000;
    EnumerableSet.UintSet eids;

    constructor(address _lzEndpoint) OApp(_lzEndpoint, msg.sender) Ownable(msg.sender) { }

    /// @dev Receive messages from other endpoints and broadcast them to other endpoints
    /// @param _origin Origin of the message
    /// @param _message Message to send
    function _lzReceive(Origin calldata _origin, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        _broadcast(_origin.srcEid, _message);
    }

    /// @dev Broadcast a message to all other endpoints
    /// @param _srcEid Source EID
    /// @param _message Message to send
    function _broadcast(uint32 _srcEid, bytes calldata _message) internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzReceiveGas, 0);

        for (uint256 i = 0; i < eids.length(); i++) {
            uint32 dstEid = uint32(eids.at(i));
            if (dstEid != _srcEid) {
                MessagingFee memory fee = _quote(dstEid, _message, options, false);
                _lzSend(dstEid, _message, options, fee, address(this));
            }
        }
    }

    /// @dev Override to set the peer for the LayerZero message
    /// @param _eid EID of the peer
    /// @param _peer Peer address
    function _setPeer(uint32 _eid, bytes32 _peer) internal override {
        super._setPeer(_eid, _peer);
        eids.add(uint256(_eid));
    }

    /// @dev Override to pay native fees from the proxy contract instead of msg.sender
    /// @param _nativeFee Native fee to pay
    /// @return nativeFee Native fee paid
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        return _nativeFee;
    }

    /// @notice Set the receive gas parameter for the LayerZero message
    /// @param _lzReceiveGas New receive gas parameter
    function setLzReceiveGas(uint128 _lzReceiveGas) external onlyOwner {
        lzReceiveGas = _lzReceiveGas;
    }

    /// @notice Allows the contract to receive native tokens
    receive() external payable { }
}
