// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice No-op interest rate model satisfying the calls Stablecoin/Underwriter/Rewarder make,
/// so those contracts can be unit tested without the real IRM coupling.
contract MockIRM {
    uint256 public updateCalls;
    mapping(bytes32 => uint256) public marketUpdateCalls;

    function update() external {
        updateCalls++;
    }

    function update(bytes32 marketId) external {
        marketUpdateCalls[marketId]++;
    }

    function variableIndex() external pure returns (uint256) {
        return 1e27;
    }

    function fixedIndex() external pure returns (uint256) {
        return 1e27;
    }

    function index(bytes32) external pure returns (uint256) {
        return 1e27;
    }
}
