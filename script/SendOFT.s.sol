// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Script, console } from "forge-std/Script.sol";

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTReceipt, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

contract SendOFT is Script, LzUtils {
    using OptionsBuilder for bytes;

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() public {
        // Fetching environment variables
        address oftAddress = vm.envAddress("OFT_ADDRESS");
        uint toChainId = vm.envUint("TO_CHAIN_ID");
        LzConfig memory toConfig = getLzConfig(vm, toChainId);
        address toAddress = vm.envAddress("TO_ADDRESS");

        uint256 _tokensToSend = vm.envUint("TOKENS_TO_SEND");

        vm.startBroadcast();

        IOFT sourceOFT = IOFT(oftAddress);

        bytes memory _extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        SendParam memory sendParam = SendParam(
            toConfig.eid, // You can also make this dynamic if needed
            addressToBytes32(toAddress),
            _tokensToSend,
            _tokensToSend * 9 / 10,
            _extraOptions,
            "",
            ""
        );

        MessagingFee memory fee = sourceOFT.quoteSend(sendParam, false);

        console.log("Fee amount: ", fee.nativeFee);

        sourceOFT.send{ value: fee.nativeFee }(sendParam, fee, msg.sender);

        // Stop broadcasting
        vm.stopBroadcast();
    }
}
