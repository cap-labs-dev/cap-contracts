// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract WalletUtils {
    function getWalletAddress() public view returns (address owner) {
        owner = tx.origin;
        if (owner == address(0)) {
            owner = msg.sender;
        }

        if (owner == address(0)) {
            revert("Owner not found");
        }

        if (owner == 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38) {
            revert("Owner is set to the default foundry address");
        }
    }
}
