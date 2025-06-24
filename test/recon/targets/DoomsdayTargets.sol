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
    /// @dev Property: liquidating a healthy agent should not generate bad debt
    function doomsday_liquidate(uint256 _amount) public stateless {
        if (_amount == 0) {
            return;
        }

        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 healthBefore) = _getAgentParams(_getActor());
        uint256 emergencyLiquidationHealth = totalDelegation * lender.emergencyLiquidationThreshold() / totalDebt;

        // Note: this function will always be called by address(this) (Liquidator will be address(this))
        try lender.liquidate(_getActor(), _getAsset(), _amount) {
            (,,,,, uint256 healthAfter) = _getAgentParams(_getActor());

            if (healthBefore > RAY) {
                gt(healthAfter, RAY, "liquidating a healthy agent should not generate bad debt");
            }
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "HealthFactorNotBelowThreshold()")
                || checkError(reason, "GracePeriodNotOver()") || checkError(reason, "LiquidationExpired()")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)")
                || checkError(reason, "InvalidBurnAmount()") || checkError(reason, "PriceError(address)");
            bool protocolPaused = capToken.paused();
            bool assetPaused = capToken.paused(_getAsset());
            (, address vault,,,,,) = lender.reservesData(_getAsset());
            bool isReserve = vault != address(0); // token must be a reserve in the lending vault

            // precondition: must not error for one of the expected reasons
            if (!expectedError && !protocolPaused && !assetPaused && totalDebt > 0 && isReserve) {
                gt(
                    emergencyLiquidationHealth,
                    RAY,
                    "Emergency liquidation is not available when emergency health is below 1e27"
                );
                gt(healthBefore, RAY, "liquidate should always succeed for liquidatable agent");
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
            bool expectedError = checkError(reason, "InvalidBurnAmount()")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)"); // fractional reserve loss
            bool enoughAllowance = MockERC20(_getAsset()).allowance(_getActor(), address(lender)) >= _amount;
            bool enoughBalance = MockERC20(_getAsset()).balanceOf(_getActor()) >= _amount;
            bool protocolPaused = capToken.paused();
            bool assetPaused = capToken.paused(_getAsset());
            (, address vault,,,,,) = lender.reservesData(_getAsset());
            bool isReserve = vault != address(0); // token must be a reserve in the lender

            if (
                !expectedError && !protocolPaused && !assetPaused && enoughAllowance && enoughBalance && _amount > 0
                    && isReserve
            ) {
                t(false, "repay should always succeed for agent that has debt");
            }
        }
    }

    /// @dev Property: repaying all debt for all actors transfers same amount of interest as would have been transferred by realizeInterest
    function doomsday_repay_all() public stateless {
        // get the maxRealization of what realizing interest would transfer to the interestReceiver
        uint256 maxRealization = lender.maxRealization(_getAsset());
        (,, address debtToken, address interestReceiver,,,) = lender.reservesData(_getAsset());

        // repay all debt for all actors, this actually transfers interest to the interestReceiver
        uint256 interestReceiverBalanceBefore = MockERC20(_getAsset()).balanceOf(interestReceiver);
        address[] memory actors = _getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 actorDebt = MockERC20(debtToken).balanceOf(actor);
            if (actorDebt > 0) {
                lender.repay(_getAsset(), actorDebt, actor);
            }
        }
        uint256 interestReceiverBalanceAfter = MockERC20(_getAsset()).balanceOf(interestReceiver);

        eq(
            interestReceiverBalanceAfter - interestReceiverBalanceBefore,
            maxRealization,
            "interestReceiver balance delta != maxRealization"
        );
    }

    /// @dev Property: borrowing and repaying an amount in the same block shouldn't change the utilization rate
    // NOTE: from previous spearbit finding
    function doomsday_manipulate_utilization_rate(uint256 _amount) public stateless {
        // get the utilization rate before a borrow
        uint256 utilizationBefore = capToken.utilization(_getAsset());
        uint256 utilizationIndexBefore = capToken.currentUtilizationIndex(_getAsset());

        // borrow some amount
        lender.borrow(_getAsset(), _amount, _getActor());

        // repay the borrowed amount
        lender.repay(_getAsset(), _amount, _getActor());

        // get the utilization rate after repaying the borrowed amount
        uint256 utilizationAfter = capToken.utilization(_getAsset());
        uint256 utilizationIndexAfter = capToken.currentUtilizationIndex(_getAsset());

        // the utilization rate should be the same as before the borrow
        eq(utilizationAfter, utilizationBefore, "utilization rate is not the same as before the borrow");
        eq(utilizationIndexAfter, utilizationIndexBefore, "utilization index is not the same as before the borrow");
    }
}
