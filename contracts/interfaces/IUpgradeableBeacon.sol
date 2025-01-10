// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IUpgradeableBeacon {
    function upgradeTo(address implementation) external;
}
