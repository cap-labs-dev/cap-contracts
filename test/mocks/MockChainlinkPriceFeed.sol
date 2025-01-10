// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockChainlinkPriceFeed {
    uint8 private _decimals;
    int256 private _latestAnswer;

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setLatestAnswer(int256 answer) external {
        _latestAnswer = answer;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestAnswer() external view returns (int256) {
        return _latestAnswer;
    }
}
