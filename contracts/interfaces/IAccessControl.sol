// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAccessControl {
    function checkRole(bytes32 _role, address _account) external view;
}
