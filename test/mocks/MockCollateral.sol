// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../contracts/interfaces/IDelegation.sol";

contract MockDelegation is IDelegation {
    mapping(address => uint256) private _coverage;
    mapping(address => uint256) private _ltv;
    mapping(address => uint256) private _liquidationThreshold;

    function coverage(address agent) external view override returns (uint256) {
        return _coverage[agent];
    }

    function slash(address agent, address _receiver, uint256 liquidatedValue) external override {
        address(_receiver);
        _coverage[agent] = _coverage[agent] > liquidatedValue ? _coverage[agent] - liquidatedValue : 0;
    }

    function ltv(address agent) external view override returns (uint256) {
        return _ltv[agent];
    }

    function liquidationThreshold(address agent) external view override returns (uint256) {
        return _liquidationThreshold[agent];
    }

    // Setter functions for testing
    function setCoverage(address agent, uint256 value) external {
        _coverage[agent] = value;
    }

    function setLtv(address agent, uint256 value) external {
        _ltv[agent] = value;
    }

    function setLiquidationThreshold(address agent, uint256 value) external {
        _liquidationThreshold[agent] = value;
    }
}
