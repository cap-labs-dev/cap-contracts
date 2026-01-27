// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IZapRouter } from "../../contracts/interfaces/IZapRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract MockZapTokenManager {
    function sendToken(address token, address from, address to, uint256 amount) external {
        MockERC20(token).transferFrom(from, to, amount);
    }
}

// Mock IZapRouter for testing
contract MockZapRouter {
    MockZapTokenManager public zapTokenManager;

    constructor() {
        zapTokenManager = new MockZapTokenManager();
    }

    function executeOrder(IZapRouter.Order calldata order, IZapRouter.Step[] calldata route) external {
        assert(route.length == 0);

        // Transfer input token directly to recipient
        IZapRouter.Input[] memory inputs = order.inputs;
        for (uint256 i = 0; i < inputs.length; i++) {
            IZapRouter.Input memory input = inputs[i];

            zapTokenManager.sendToken(input.token, order.user, order.recipient, input.amount);
        }
    }
}
