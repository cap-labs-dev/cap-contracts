// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

contract MockStakedLBTCOracle {
    uint256 private _rate;

    constructor(uint256 rate_) {
        _rate = rate_;
    }

    function getRate() external view returns (uint256) {
        return _rate;
    }

    function setRate(uint256 rate_) external {
        _rate = rate_;
    }
}
