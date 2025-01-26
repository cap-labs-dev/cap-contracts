// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IBeefyZapRouter } from "../../contracts/interfaces/IBeefyZapRouter.sol";
import { IZapOFTComposer } from "../../contracts/interfaces/IZapOFTComposer.sol";

import { ZapOFTComposer } from "../../contracts/zap/ZapOFTComposer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { Test } from "forge-std/Test.sol";

contract MockZapTokenManager {
    function sendToken(address token, address from, address to, uint256 amount) external {
        MockERC20(token).transferFrom(from, to, amount);
    }
}

// Mock BeefyZapRouter for testing
contract MockBeefyZapRouter {
    MockZapTokenManager public zapTokenManager;

    constructor() {
        zapTokenManager = new MockZapTokenManager();
    }

    function executeOrder(IBeefyZapRouter.Order calldata order, IBeefyZapRouter.Step[] calldata route) external {
        assert(route.length == 0);

        // Transfer input token directly to recipient
        IBeefyZapRouter.Input[] memory inputs = order.inputs;
        for (uint256 i = 0; i < inputs.length; i++) {
            IBeefyZapRouter.Input memory input = inputs[i];

            zapTokenManager.sendToken(input.token, order.user, order.recipient, input.amount);
        }
    }
}

contract ZapOFTComposerTest is Test {
    ZapOFTComposer public composer;
    MockERC20 public token;
    MockBeefyZapRouter public zapRouter;
    address public user;
    address public recipient;
    address public zapTokenManager;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        token = new MockERC20("Token1", "TK1", 18);
        zapRouter = new MockBeefyZapRouter();

        composer = new ZapOFTComposer(address(0), address(0), address(zapRouter), address(zapRouter.zapTokenManager()));

        // Setup initial balances
        token.mint(address(composer), 1000e18);
    }

    function test_lzCompose_Success() public {
        bytes memory message = _getTransferZapMessage(user, 100e18, address(token), address(composer), recipient, 50e18);

        vm.prank(address(composer));
        composer.safeLzCompose(address(0), bytes32(0), message, address(0), bytes(""));

        // Verify tokens were minted to user
        assertEq(token.balanceOf(recipient), 50e18);
    }

    function _getTransferZapMessage(
        address _srcChainSender,
        uint256 _amountLD,
        address _token,
        address _from,
        address _to,
        uint256 _zapAmount
    ) internal pure returns (bytes memory) {
        IZapOFTComposer.ZapMessage memory zapMessage;
        {
            IBeefyZapRouter.Input[] memory inputs = new IBeefyZapRouter.Input[](1);
            inputs[0] = IBeefyZapRouter.Input({ token: _token, amount: _zapAmount });

            IBeefyZapRouter.Output[] memory outputs = new IBeefyZapRouter.Output[](1);
            outputs[0] = IBeefyZapRouter.Output({ token: _token, minOutputAmount: _zapAmount });

            IBeefyZapRouter.Relay memory noopRelay = IBeefyZapRouter.Relay({ target: address(0), value: 0, data: "" });

            IBeefyZapRouter.Order memory order = IBeefyZapRouter.Order({
                inputs: inputs,
                outputs: outputs,
                relay: noopRelay,
                user: _from,
                recipient: _to
            });
            IBeefyZapRouter.Step[] memory route = new IBeefyZapRouter.Step[](0);

            zapMessage = IZapOFTComposer.ZapMessage({ order: order, route: route });
        }

        uint64 _nonce = 0;
        uint32 _srcEid = 0;
        bytes memory payload =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(_srcChainSender), abi.encode(zapMessage));
        return OFTComposeMsgCodec.encode(_nonce, _srcEid, _amountLD, payload);
    }
}
