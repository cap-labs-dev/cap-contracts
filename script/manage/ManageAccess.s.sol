// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { IMinter } from "../../contracts/interfaces/IMinter.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract ManageAccess is Script {
    function run() external {
        vm.startBroadcast();
        AccessControl accessControl = AccessControl(0x32fd97A5196a6D98656a7F2f191Ae4732ad13170);
        accessControl.grantAccess(
            IMinter.setWhitelist.selector,
            address(0xF79e8E7Ba2dDb5d0a7D98B1F57fCb8A50436E9aA),
            address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52)
        );
        vm.stopBroadcast();
    }
}
