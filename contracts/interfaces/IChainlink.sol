// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IChainlink {
    function latestAnswer() external view returns (int256);
}