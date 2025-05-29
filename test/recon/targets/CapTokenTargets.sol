// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import { IMinter } from "contracts/interfaces/IMinter.sol";
import "contracts/token/CapToken.sol";

abstract contract CapTokenTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function capToken_addAsset(address _asset) public asActor {
        capToken.addAsset(_asset);
    }

    function capToken_approve(address spender, uint256 value) public asActor {
        capToken.approve(spender, value);
    }

    function capToken_borrow(address _asset, uint256 _amount, address _receiver) public asActor {
        capToken.borrow(_asset, _amount, _receiver);
    }

    function capToken_burn(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) public asActor {
        capToken.burn(_asset, _amountIn, _minAmountOut, _receiver, _deadline);
    }

    function capToken_divestAll(address _asset) public asActor {
        capToken.divestAll(_asset);
    }

    function capToken_investAll(address _asset) public asActor {
        capToken.investAll(_asset);
    }

    function capToken_mint(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) public asActor {
        capToken.mint(_asset, _amountIn, _minAmountOut, _receiver, _deadline);
    }

    function capToken_pauseAsset(address _asset) public asActor {
        capToken.pauseAsset(_asset);
    }

    function capToken_pauseProtocol() public asActor {
        capToken.pauseProtocol();
    }

    function capToken_permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public asActor {
        capToken.permit(owner, spender, value, deadline, v, r, s);
    }

    function capToken_realizeInterest(address _asset) public asActor {
        capToken.realizeInterest(_asset);
    }

    function capToken_redeem(uint256 _amountIn, uint256[] memory _minAmountsOut, address _receiver, uint256 _deadline)
        public
        asActor
    {
        capToken.redeem(_amountIn, _minAmountsOut, _receiver, _deadline);
    }

    function capToken_removeAsset(address _asset) public asActor {
        capToken.removeAsset(_asset);
    }

    function capToken_repay(address _asset, uint256 _amount) public asActor {
        capToken.repay(_asset, _amount);
    }

    function capToken_rescueERC20(address _asset, address _receiver) public asActor {
        capToken.rescueERC20(_asset, _receiver);
    }

    function capToken_setFeeData(address _asset, IMinter.FeeData memory _feeData) public asActor {
        capToken.setFeeData(_asset, _feeData);
    }

    function capToken_setFractionalReserveVault(address _asset, address _vault) public asActor {
        capToken.setFractionalReserveVault(_asset, _vault);
    }

    function capToken_setRedeemFee(uint256 _redeemFee) public asActor {
        capToken.setRedeemFee(_redeemFee);
    }

    function capToken_setReserve(address _asset, uint256 _reserve) public asActor {
        capToken.setReserve(_asset, _reserve);
    }

    function capToken_transfer(address to, uint256 value) public asActor {
        capToken.transfer(to, value);
    }

    function capToken_transferFrom(address from, address to, uint256 value) public asActor {
        capToken.transferFrom(from, to, value);
    }

    function capToken_unpauseAsset(address _asset) public asActor {
        capToken.unpauseAsset(_asset);
    }

    function capToken_unpauseProtocol() public asActor {
        capToken.unpauseProtocol();
    }
}
