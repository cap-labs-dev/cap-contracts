// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { IZapRouter } from "../interfaces/IZapRouter.sol";

/// @title ZapOFTComposer
/// @author kexley, Cap Labs
/// @notice Compose an OFT with Zap capabilities
interface IZapOFTComposer {
    /// @dev Zap message
    /// @param order The zap order to execute
    /// @param route The zap route to execute
    struct ZapMessage {
        IZapRouter.Order order;
        IZapRouter.Step[] route;
    }
}
