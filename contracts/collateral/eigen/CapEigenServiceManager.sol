// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Network} from "../Network.sol";

import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {ServiceManagerBase, IRewardsCoordinator, IRegistryCoordinator, IStakeRegistry} from "eigenlayer/src/ServiceManagerBase.sol";

contract CapEigenServiceManager is ServiceManagerBase {
    constructor(
        IAVSDirectory __avsDirectory,
        IRewardsCoordinator __rewardsCoordinator,
        IRegistryCoordinator __registryCoordinator,
        IStakeRegistry __stakeRegistry
    ) ServiceManagerBase(__avsDirectory, __rewardsCoordinator, __registryCoordinator, __stakeRegistry) {
        _disableInitializers();
    } 

    function initialize(address initialOwner, address rewards) public {}
}