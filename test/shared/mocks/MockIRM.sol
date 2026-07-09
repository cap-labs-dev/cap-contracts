// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice No-op interest rate model satisfying the calls Stablecoin/Market/Rewarder make.
contract MockIRM {
    uint256 public updateCalls;
    mapping(address => uint256) public marketUpdateCalls;

    function update() external {
        updateCalls++;
    }

    function update(address market) external {
        marketUpdateCalls[market]++;
    }

    function setInterestType(address, bool) external pure { }

    function variableIndex() external pure returns (uint256) {
        return 1e27;
    }

    function fixedIndex() external pure returns (uint256) {
        return 1e27;
    }

    function supplyIndex(address) external pure returns (uint256) {
        return 1e27;
    }

    function trancheIndex(address) external pure returns (uint256) {
        return 1e27;
    }

    function index(address) external pure returns (uint256, uint256) {
        return (1e27, 1e27);
    }
}
