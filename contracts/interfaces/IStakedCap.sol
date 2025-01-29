// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IStakedCap is IERC4626 {
    function initialize(address _asset, address _registry) external;
}
