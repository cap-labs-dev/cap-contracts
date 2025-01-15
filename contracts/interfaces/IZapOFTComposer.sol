// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "./IBeefyZapRouter.sol";

struct OFTZapMessage {
    uint256 value;
    IBeefyZapRouter.Order order;
    IBeefyZapRouter.Step[] route;
}
