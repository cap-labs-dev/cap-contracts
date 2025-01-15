// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAuctionCallback {
    function auctionCallback(
        address[] calldata _assets,
        uint256[] calldata balances,
        uint256 price,
        bytes calldata callback
    ) external;
}
