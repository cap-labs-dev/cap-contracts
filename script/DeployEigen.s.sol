// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../contracts/access/AccessControl.sol";

import { Delegation } from "../contracts/delegation/Delegation.sol";
import { EigenAgentManager } from "../contracts/delegation/providers/eigenlayer/EigenAgentManager.sol";
import {
    EigenServiceManager,
    IEigenServiceManager
} from "../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";

import { IRateOracle } from "../contracts/interfaces/IRateOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        address _accessControl = 0x7731129a10d51e18cDE607C5C115F26503D2c683;
        IEigenServiceManager.EigenAddresses memory _eigenAddresses = IEigenServiceManager.EigenAddresses({
            allocationManager: 0x948a420b8CC1d6BFd0B6087C2E7c344a2CD0bc39,
            delegationManager: 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A,
            strategyManager: 0x858646372CC42E1A627fcE94aa7A7033e7CF075A,
            rewardsCoordinator: 0x7750d328b314EfFa365A0402CcfD489B80B0adda
        });
        address _oracle = 0xcD7f45566bc0E7303fB92A93969BB4D3f6e662bb;
        uint32 _epochDuration = uint32(7);

        vm.startBroadcast();
        EigenServiceManager eigenServiceManager = new EigenServiceManager();
        console.log("EigenServiceManagerImplementation deployed to:", address(eigenServiceManager));

        bytes memory initParams = abi.encodeWithSelector(
            EigenServiceManager.initialize.selector, _accessControl, _eigenAddresses, _oracle, _epochDuration
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(eigenServiceManager), initParams);
        console.log("EigenServiceManager proxy deployed to:", address(proxy));

        EigenAgentManager eigenAgentManager = new EigenAgentManager();
        console.log("EigenAgentManagerImplementation deployed to:", address(eigenAgentManager));

        address _lender = 0x15622c3dbbc5614E6DFa9446603c1779647f01FC;
        address _cusd = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
        address _delegation = 0xF3E3Eae671000612CE3Fd15e1019154C1a4d693F;
        address _serviceManager = 0xBde7c8DB7a546526dD99d23796bAa24c80c5036b;

        initParams = abi.encodeWithSelector(
            EigenAgentManager.initialize.selector, _accessControl, _lender, _cusd, _delegation, _serviceManager, _oracle
        );

        ERC1967Proxy eigenAgentManagerProxy = new ERC1967Proxy(address(eigenAgentManager), initParams);
        console.log("EigenAgentManagerProxy deployed to:", address(eigenAgentManagerProxy));

        console.log("EigenServiceManager.slash");
        console.logBytes4(EigenServiceManager.slash.selector);
        console.log("EigenServiceManager.distributeRewards");
        console.logBytes4(EigenServiceManager.distributeRewards.selector);
        console.log("EigenServiceManager.registerOperator");
        console.logBytes4(EigenServiceManager.registerOperator.selector);
        console.log("EigenServiceManager.registerStrategy");
        console.logBytes4(EigenServiceManager.registerStrategy.selector);
        console.log("EigenServiceManager.setEpochsBetweenDistributions");
        console.logBytes4(EigenServiceManager.setEpochsBetweenDistributions.selector);
        console.log("EigenServiceManager.upgradeEigenOperatorImplementation");
        console.logBytes4(EigenServiceManager.upgradeEigenOperatorImplementation.selector);

        console.log("EigenAgentManager.addEigenAgent");
        console.logBytes4(EigenAgentManager.addEigenAgent.selector);
        console.log("EigenAgentManager.setRestakerRate");
        console.logBytes4(EigenAgentManager.setRestakerRate.selector);

        console.log("Delegation.addAgent");
        console.logBytes4(Delegation.addAgent.selector);

        console.log("IRateOracle.setRestakerRate");
        console.logBytes4(IRateOracle.setRestakerRate.selector);

        vm.stopBroadcast();
    }
}
