// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { LibsConfig } from "../interfaces/DeployConfigs.sol";

contract DeployLibs {
    function _deployLibs() internal pure returns (LibsConfig memory libs) {
        libs.unused = address(0);
    }
}
