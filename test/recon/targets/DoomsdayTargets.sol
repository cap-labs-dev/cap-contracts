// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { MockERC20 } from "@recon/MockERC20.sol";

// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";
import { console2 } from "forge-std/console2.sol";

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// Makes a handler have no side effects
    /// The fuzzer will call this anyway, and because it reverts it will be removed from shrinking
    /// Replace the "withGhosts" with "stateless" to make the code clean
    modifier stateless() {
        _;
        revert("stateless");
    }

    /// @dev Property: liquidate should always succeed for liquidatable agent
    /// @dev Property: Emergency liquidations should always be available when emergency health is below 1e27
    function doomsday_liquidate(uint256 _amount) public stateless {
        if (_amount == 0) {
            return;
        }

        (uint256 totalDelegation,, uint256 totalDebt,,,) = lender.agent(_getActor());

        // Note: this function will always be called by address(this) (Liquidator will be address(this))
        try lender.liquidate(_getActor(), _getAsset(), _amount) {
            // success
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "HealthFactorNotBelowThreshold()")
                || checkError(reason, "GracePeriodNotOver()") || checkError(reason, "LiquidationExpired()");
            bool zeroBurnError = checkError(reason, "InvalidBurnAmount()");
            bool isPaused = capToken.paused();

            // precondition: must be liquidating more than 0 and not paused
            if (!isPaused && !zeroBurnError) {
                gte(
                    totalDelegation * lender.emergencyLiquidationThreshold() / totalDebt,
                    RAY,
                    "Emergency liquidation is not available when emergency health is below 1e27"
                );
            }

            if (!expectedError && !isPaused && !zeroBurnError && totalDebt > 0) {
                t(false, "liquidate should always succeed for liquidatable agent");
            }
        }
    }

    /// @dev Property: repay should always succeed for agent that has debt
    function doomsday_repay(uint256 _amount) public stateless {
        (,, uint256 totalDebt,,,) = lender.agent(_getActor());

        // Preconditions: should have debt, enough allowance and balance to repay
        if (
            totalDebt == 0 || MockERC20(_getAsset()).allowance(_getActor(), address(lender)) < _amount
                || MockERC20(_getAsset()).balanceOf(_getActor()) < _amount
        ) {
            return;
        }
        vm.prank(_getActor());
        try lender.repay(_getAsset(), _amount, _getActor()) {
            // success
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "InvalidBurnAmount()");
            bool enoughAllowance = MockERC20(_getAsset()).allowance(_getActor(), address(lender)) >= _amount;
            bool enoughBalance = MockERC20(_getAsset()).balanceOf(_getActor()) >= _amount;
            bool paused = capToken.paused();

            if (!expectedError && !paused && enoughAllowance && enoughBalance && _amount > 0) {
                t(false, "repay should always succeed for agent that has debt");
            }
        }
    }
}
