// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ILender {
    function oracle() external view returns (address oracle);
}