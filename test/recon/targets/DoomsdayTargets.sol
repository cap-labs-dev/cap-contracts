// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { MockERC20 } from "@recon/MockERC20.sol";

// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// Makes a handler have no side effects
    /// The fuzzer will call this anyway, and because it reverts it will be removed from shrinking
    /// Replace the "withGhosts" with "stateless" to make the code clean
    modifier stateless() {
        _;
        revert("stateless");
    }

    /// @dev Property: liquidate should always succeed for liquidatable agent
    function doomsday_liquidate(uint256 _amount) public asActor {
        if (_amount == 0) {
            return;
        }

        (,, uint256 totalDebt,,,) = lender.agent(_getActor());

        try lender.liquidate(_getActor(), _getAsset(), _amount) {
            // success
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "HealthFactorNotBelowThreshold()")
                || checkError(reason, "GracePeriodNotOver()") || checkError(reason, "LiquidationExpired()");

            if (!expectedError && totalDebt > 0) {
                t(false, "liquidate should always succeed for liquidatable agent");
            }
        }
    }

    /// @dev Property: repay should always succeed for agent that has debt
    function doomsday_repay(uint256 _amount) public asActor {
        (,, uint256 totalDebt,,,) = lender.agent(_getActor());

        // Preconditions: should have debt, enough allowance and balance to repay
        if (
            totalDebt == 0 && MockERC20(_getAsset()).allowance(_getActor(), address(lender)) < _amount
                && MockERC20(_getAsset()).balanceOf(_getActor()) < _amount
        ) {
            return;
        }
        try lender.repay(_getAsset(), _amount, _getActor()) {
            // success
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "InvalidBurnAmount()");
            bool paused = capToken.paused();

            if (!expectedError && !paused) {
                t(false, "repay should always succeed for agent that has debt");
            }
        }
    }
}
