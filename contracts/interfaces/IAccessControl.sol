// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAccessControl {
    function checkRole(bytes4 _selector, address _contract, address _caller) external view;
}
