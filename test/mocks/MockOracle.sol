// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public marketIndices;
    mapping(address => uint256) public agentIndices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function setMarketIndex(address asset, uint256 index) external {
        marketIndices[asset] = index;
    }

    function setAgentIndex(address agent, uint256 index) external {
        agentIndices[agent] = index;
    }

    function getPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }

    function marketIndex(address asset) external view override returns (uint256) {
        return marketIndices[asset];
    }

    function agentIndex(address agent) external view override returns (uint256) {
        return agentIndices[agent];
    }
} 