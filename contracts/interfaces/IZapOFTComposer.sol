// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";

/// @author @caplabs
interface IZapOFTComposer {
    struct ZapMessage {
        /// @notice The zap order to execute.
        IBeefyZapRouter.Order order;
        /// @notice The zap route to execute.
        IBeefyZapRouter.Step[] route;
    }
}
