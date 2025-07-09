// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { IMinter } from "../../contracts/interfaces/IMinter.sol";
import { IPriceOracle } from "../../contracts/interfaces/IPriceOracle.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract ManageAccess is Script {
    function run() external {
        vm.startBroadcast();
        AccessControl accessControl = AccessControl(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        accessControl.grantAccess(
            IPriceOracle.setStaleness.selector,
            address(0xcD7f45566bc0E7303fB92A93969BB4D3f6e662bb),
            address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52)
        );
        vm.stopBroadcast();
    }
}
