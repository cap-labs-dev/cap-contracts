// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IZapRouter } from "../interfaces/IZapRouter.sol";

/// @author @caplabs
interface IZapOFTComposer {
    struct ZapMessage {
        /// @notice The zap order to execute.
        IZapRouter.Order order;
        /// @notice The zap route to execute.
        IZapRouter.Step[] route;
    }
}
