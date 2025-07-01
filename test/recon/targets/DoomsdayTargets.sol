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
                || checkError(reason, "InvalidBurnAmount()") || checkError(reason, "PriceError(address)")
                || checkError(reason, "InsufficientAllowance(address,address,uint256,uint256)")
                || checkError(reason, "InsufficientBalance(address,uint256,uint256)");
            bool protocolPaused = capToken.paused();
            bool assetPaused = capToken.paused(_getAsset());
            (, address vault,,,,,) = lender.reservesData(_getAsset());
            bool isReserve = vault != address(0); // token must be a reserve in the lending vault

            bool enoughBalance = MockERC20(_getAsset()).balanceOf(address(this)) >= _amount;
            bool enoughAllowance = MockERC20(_getAsset()).allowance(address(this), address(lender)) >= _amount;

            // precondition: must not error for one of the expected reasons
            if (
                !expectedError && !protocolPaused && !assetPaused && totalDebt > 0 && isReserve && enoughBalance
                    && enoughAllowance
            ) {
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

    /// @dev Property: DebtToken total supply ≥ total vault debt at all times
    // NOTE: stateless because we're realizing restaker interest since this contributes to the total vault debt
    function doomsday_debt_token_solvency() public stateless {
        address[] memory assets = capToken.assets();
        address[] memory agents = delegation.agents();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            (,, address _debtToken,,,,) = lender.reservesData(asset);

            if (_debtToken == address(0)) {
                continue;
            }

            // realize restaker interest for all agents so that we have the correct amount of debtToken minted to each agent
            for (uint256 j = 0; j < agents.length; j++) {
                vm.prank(agents[j]);
                lender.realizeRestakerInterest(agents[j], asset);
            }

            uint256 totalDebtTokenSupply = MockERC20(_debtToken).totalSupply();

            uint256 totalVaultDebt = 0;
            uint256 totalDebtTokenBalance = 0;
            for (uint256 j = 0; j < agents.length; j++) {
                totalDebtTokenBalance += MockERC20(_debtToken).balanceOf(agents[j]);
                totalVaultDebt += lender.debt(agents[j], asset);
            }
            console2.log("totalDebtTokenBalance %e", totalDebtTokenBalance);
            console2.log("totalVaultDebt %e", totalVaultDebt);
            console2.log("totalDebtTokenSupply %e", totalDebtTokenSupply);

            eq(totalDebtTokenSupply, totalVaultDebt, "DebtToken totalSupply < total vault debt");
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
                vm.prank(actor);
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
        uint256 totalDebtBefore = lender.debt(_getActor(), _getAsset());

        // borrow some amount
        vm.prank(_getActor());
        lender.borrow(_getAsset(), _amount, _getActor());

        uint256 totalDebtAfterBorrow = lender.debt(_getActor(), _getAsset());
        // this is the additional debt that was borrowed in this sequence only, we don't care about debt from other calls
        uint256 additionalDebt = totalDebtAfterBorrow - totalDebtBefore;

        // repay the borrowed amount
        vm.prank(_getActor());
        uint256 repaid = lender.repay(_getAsset(), _amount, _getActor());

        // get the utilization rate after repaying the borrowed amount
        uint256 utilizationAfter = capToken.utilization(_getAsset());
        uint256 utilizationIndexAfter = capToken.currentUtilizationIndex(_getAsset());

        // precondition: the amount repaid is less than or equal to the additional debt borrowed in this sequence
        if (repaid <= additionalDebt) {
            // the utilization rate should be the same as before the borrow
            eq(utilizationAfter, utilizationBefore, "utilization rate is not the same as before the borrow");
            eq(utilizationIndexAfter, utilizationIndexBefore, "utilization index is not the same as before the borrow");
        }
    }

    /// @dev optimizes the difference in utilization discovered by doomsday_manipulate_utilization_rate
    function doomsday_manipulate_utilization_rate_optimization(uint256 _amount) public {
        // get the utilization rate before a borrow
        uint256 utilizationBefore = capToken.utilization(_getAsset());

        // borrow some amount
        vm.prank(_getActor());
        lender.borrow(_getAsset(), _amount, _getActor());

        // repay the borrowed amount
        vm.prank(_getActor());
        lender.repay(_getAsset(), _amount, _getActor());

        // get the utilization rate after repaying the borrowed amount
        uint256 utilizationAfter = capToken.utilization(_getAsset());

        if (utilizationAfter > utilizationBefore) {
            int256 increase = int256(utilizationAfter) - int256(utilizationBefore);
            if (increase > maxUtilizationIncrease) {
                maxUtilizationIncrease = increase;
            }
        } else {
            int256 decrease = int256(utilizationBefore) - int256(utilizationAfter);
            if (decrease > maxUtilizationDecrease) {
                maxUtilizationDecrease = decrease;
            }
        }
    }

    /// @dev Property: maxBorrowable after borrowing max should be 0
    /// @dev Property: borrowing max should not make agent unhealthy
    function doomsday_maxBorrow() public stateless {
        uint256 maxBorrowBefore = lender.maxBorrowable(_getActor(), _getAsset());

        vm.prank(_getActor());
        lender.borrow(_getAsset(), maxBorrowBefore, _getActor());

        uint256 maxBorrowAfter = lender.maxBorrowable(_getActor(), _getAsset());
        (,,,,, uint256 health) = lender.agent(_getActor());

        eq(maxBorrowAfter, 0, "max borrow should be 0 after borrowing max");
        gt(health, RAY, "agent should be healthy after borrowing max");
    }

    /// @dev Property: realizeRestakerInterest never reverts due to under/overflow
    function doomsday_realizeRestakerInterest_never_reverts() public stateless {
        try lender.realizeRestakerInterest(_getActor(), _getAsset()) {
            // success
        } catch (bytes memory reason) {
            bool underflowError = checkError(reason, Panic.arithmeticPanic);
            t(!underflowError, "realizeRestakerInterest should never revert");
        }
    }
}
