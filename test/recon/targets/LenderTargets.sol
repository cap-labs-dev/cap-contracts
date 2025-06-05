// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { MockERC20 } from "@recon/MockERC20.sol";
import { Panic } from "@recon/Panic.sol";

import { ILender } from "contracts/interfaces/ILender.sol";

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

abstract contract LenderTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function lender_borrow_clamped(uint256 _amount) public {
        lender_borrow(_getAsset(), _amount, agent);
    }

    function lender_initiateLiquidation_clamped() public {
        lender_initiateLiquidation(agent);
    }

    function lender_cancelLiquidation_clamped() public {
        lender_cancelLiquidation(agent);
    }

    function lender_liquidate_clamped(uint256 _amount) public {
        lender_liquidate(agent, _getAsset(), _amount);
    }

    function lender_repay_clamped(uint256 _amount) public {
        lender_repay(_getAsset(), _amount, agent);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function lender_addAsset(ILender.AddAssetParams memory _params) public asAdmin {
        lender.addAsset(_params);
    }

    function lender_borrow(address _asset, uint256 _amount, address _receiver) public asAgent {
        lender.borrow(_asset, _amount, _receiver);
    }

    function lender_cancelLiquidation(address _agent) public asActor {
        lender.cancelLiquidation(_agent);
    }

    function lender_initiateLiquidation(address _agent) public asActor {
        lender.initiateLiquidation(_agent);
    }

    function lender_liquidate(address _agent, address _asset, uint256 _amount) public asActor {
        lender.liquidate(_agent, _asset, _amount);
    }

    function lender_pauseAsset(address _asset, bool _pause) public asAdmin {
        lender.pauseAsset(_asset, _pause);
    }

    /// @dev Property: realizeInterest should only revert with ZeroRealization if paused or totalUnrealizedInterest == 0, otherwise should always update the realization value
    function lender_realizeInterest(address _asset) public asActor {
        try lender.realizeInterest(_asset) {
            // success
        } catch (bytes memory reason) {
            bool zeroRealizationError = checkError(reason, "ZeroRealization()");

            (,,,,, bool paused,) = ILender(address(lender)).reservesData(_asset);
            uint256 totalUnrealizedInterest = LenderWrapper(address(lender)).getTotalUnrealizedInterest(_asset);

            if (!paused && totalUnrealizedInterest != 0) {
                t(!zeroRealizationError, "realizeInterest does not update when it should");
            }
        }
    }

    function lender_realizeRestakerInterest(address _agent, address _asset) public asActor {
        lender.realizeRestakerInterest(_agent, _asset);
    }

    function lender_removeAsset(address _asset) public asAdmin {
        lender.removeAsset(_asset);
    }

    /// @dev Property: Repay should never revert due to under/overflow
    function lender_repay(address _asset, uint256 _amount, address _agent) public asActor {
        try lender.repay(_asset, _amount, _agent) {
            // success
        } catch (bytes memory reason) {
            bool underflowError = checkError(reason, Panic.arithmeticPanic);

            t(!underflowError, "underflow error");
        }
    }

    function lender_setMinBorrow(address _asset, uint256 _minBorrow) public asAdmin {
        lender.setMinBorrow(_asset, _minBorrow);
    }
}
