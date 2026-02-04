// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

contract MockAuction {
    uint256 public startBlock;
    uint256 public endBlock;

    constructor(uint256 _startBlock, uint256 _endBlock) {
        startBlock = _startBlock;
        endBlock = _endBlock;
    }
}
