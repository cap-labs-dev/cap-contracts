// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";

// Helpers

import { OpType } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { Panic } from "@recon/Panic.sol";
import { DebtToken } from "contracts/lendingPool/tokens/DebtToken.sol";
import { console2 } from "forge-std/console2.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

import "contracts/lendingPool/Lender.sol";

abstract contract LenderTargets is BaseTargetFunctions, Properties {
    uint256 constant RAY = 1e27;

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function lender_borrow_clamped(uint256 _amount) public {
        lender_borrow(_getAsset(), _amount, _getActor());
    }

    function lender_initiateLiquidation_clamped() public {
        lender_initiateLiquidation();
    }

    function lender_cancelLiquidation_clamped() public {
        lender_cancelLiquidation();
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function lender_addAsset(
        address asset,
        address vault,
        address debtToken,
        address interestReceiver,
        uint256 bonusCap,
        uint256 minBorrow
    ) public updateGhosts asAdmin {
        ILender.AddAssetParams memory params = ILender.AddAssetParams({
            asset: asset,
            vault: vault,
            debtToken: debtToken,
            interestReceiver: interestReceiver,
            bonusCap: bonusCap,
            minBorrow: minBorrow
        });
        lender.addAsset(params);
    }

    /// @dev Property: Asset cannot be borrowed when it is paused
    /// @dev Property: Borrower should be healthy after borrowing (self-liquidation)
    /// @dev Property: Borrower asset balance should increase after borrowing
    /// @dev Property: Borrower debt should increase after borrowing
    /// @dev Property: Total borrows should increase after borrowing
    /// @dev Property: Borrower can't borrow more than LTV
    function lender_borrow(address _asset, uint256 _amount, address _receiver)
        public
        updateGhostsWithType(OpType.BORROW)
        asActor
    {
        uint256 beforeAssetBalance = MockERC20(_asset).balanceOf(_receiver);
        (,, address _debtToken,,,,) = lender.reservesData(_asset);
        uint256 beforeBorrowerDebt = DebtToken(_debtToken).balanceOf(_getActor());
        uint256 beforeMaxBorrowable = lender.maxBorrowable(_getActor(), _asset);

        vm.prank(_getActor());
        try lender.borrow(_asset, _amount, _receiver) {
            uint256 borrowerDebtDelta = DebtToken(_debtToken).balanceOf(_getActor()) - beforeBorrowerDebt;

            t(!capToken.paused() && !capToken.paused(_asset), "asset can be borrowed when it is paused");

            (,,,,, uint256 health) = lender.agent(_getActor());
            gt(health, RAY, "Borrower is unhealthy after borrowing");

            gt(
                DebtToken(_debtToken).balanceOf(_getActor()),
                beforeBorrowerDebt,
                "Borrower debt did not increase after borrowing"
            );
            if (_amount == type(uint256).max) {
                eq(
                    MockERC20(_asset).balanceOf(_receiver),
                    beforeAssetBalance + beforeMaxBorrowable,
                    "Borrower asset balance did not increase after borrowing (in case of max borrow)"
                );
            } else {
                eq(
                    MockERC20(_asset).balanceOf(_receiver),
                    beforeAssetBalance + _amount,
                    "Borrower asset balance did not increase after borrowing"
                );
            }

            (uint256 assetPrice,) = oracle.getPrice(_asset);
            (uint256 collateralValue,) =
                mockNetworkMiddleware.coverageByVault(address(0), _getActor(), mockEth, address(0), 0);

            lte(
                (borrowerDebtDelta * assetPrice / 10 ** MockERC20(_asset).decimals()) * RAY / collateralValue,
                delegation.ltv(_getActor()),
                "Borrower can't borrow more than LTV"
            );
        } catch (bytes memory reason) { }
    }

    function lender_cancelLiquidation() public updateGhosts asActor {
        lender.cancelLiquidation(_getActor());
    }

    /// @dev Property: Agent should not be liquidatable with health > 1e27
    /// @dev Property: Agent should always be liquidatable if it is unhealthy
    function lender_initiateLiquidation() public updateGhosts asActor {
        (,,,,, uint256 healthBefore) = lender.agent(_getActor());

        try lender.initiateLiquidation(_getActor()) {
            if (healthBefore > RAY) {
                t(false, "agent should not be liquidatable with health > 1e27");
            }
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "AlreadyInitiated()");

            if (!expectedError) {
                gte(healthBefore, RAY, "Agent should always be liquidatable if it is unhealthy");
            }
        }
    }

    /// @dev Property: agent should not be liquidatable with health > 1e27
    /// @dev Property: Liquidations should always improve the health factor
    /// @dev Property: Emergency liquidations should always be available when emergency health is below 1e27
    function lender_liquidate(uint256 _amount) public updateGhosts asActor {
        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 healthBefore) = lender.agent(_getActor());

        try lender.liquidate(_getActor(), _getAsset(), _amount) {
            if (healthBefore > 1e27) {
                t(false, "agent should not be liquidatable with health > 1e27");
            }
            (,,,,, uint256 healthAfter) = lender.agent(_getActor());
            gt(healthAfter, healthBefore, "Liquidation did not improve health factor");
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "InvalidBurnAmount()");
            // precondition: must be liquidating more than 0
            if (!expectedError) {
                gte(
                    totalDelegation * lender.emergencyLiquidationThreshold() / totalDebt,
                    RAY,
                    "Emergency liquidations is not available when emergency health is below 1e27"
                );
            }
        }
    }

    function lender_pauseAsset(bool _pause) public updateGhosts asAdmin {
        lender.pauseAsset(_getAsset(), _pause);
    }

    /// @dev Property: realizeInterest should only revert with ZeroRealization if paused or totalUnrealizedInterest == 0, otherwise should always update the realization value
    /// @dev Property: agent's total debt should not change when interest is realized
    function lender_realizeInterest() public updateGhostsWithType(OpType.REALIZE_INTEREST) {
        (,, uint256 totalDebtBefore,,,) = _getAgentParams(_getActor());
        uint256 vaultDebtBefore = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 vaultAssetBalanceBefore = MockERC20(_getAsset()).balanceOf(address(capToken));

        vm.prank(_getActor());
        try lender.realizeInterest(_getAsset()) {
            (,, uint256 totalDebtAfter,,,) = _getAgentParams(_getActor());
            uint256 vaultDebtAfter = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
            uint256 vaultAssetBalanceAfter = MockERC20(_getAsset()).balanceOf(address(capToken));

            eq(totalDebtAfter, totalDebtBefore, "agent total debt should not change after realizeInterest");
            eq(
                vaultDebtAfter - vaultDebtBefore,
                vaultAssetBalanceBefore - vaultAssetBalanceAfter,
                "vault debt increase != asset decrease in realizeInterest"
            );
            // success
        } catch (bytes memory reason) {
            bool zeroRealizationError = checkError(reason, "ZeroRealization()");

            (,,,,, bool paused,) = lender.reservesData(_getAsset());
            uint256 totalUnrealizedInterest = LenderWrapper(address(lender)).getTotalUnrealizedInterest(_getAsset());

            if (!paused && totalUnrealizedInterest != 0) {
                t(!zeroRealizationError, "realizeInterest does not update when it should");
            }
        }
    }

    function lender_realizeRestakerInterest(address _asset)
        public
        updateGhostsWithType(OpType.REALIZE_INTEREST)
        asActor
    {
        uint256 vaultDebtBefore = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 vaultAssetBalanceBefore = MockERC20(_getAsset()).balanceOf(address(capToken));
        (,, uint256 totalDebtBefore,,,) = _getAgentParams(_getActor());

        lender.realizeRestakerInterest(_getActor(), _asset);

        uint256 vaultDebtAfter = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 vaultAssetBalanceAfter = MockERC20(_getAsset()).balanceOf(address(capToken));
        (,, uint256 totalDebtAfter,,,) = _getAgentParams(_getActor());

        eq(
            vaultDebtAfter - vaultDebtBefore,
            vaultAssetBalanceBefore - vaultAssetBalanceAfter,
            "vault debt increase != asset decrease in realizeRestakerInterest"
        );
        eq(totalDebtAfter, totalDebtBefore, "agent total debt should not change after realizeRestakerInterest");
    }

    function lender_removeAsset(address _asset) public updateGhosts asAdmin {
        lender.removeAsset(_asset);
    }

    /// @dev Property: Repay should never revert due to under/overflow
    function lender_repay(uint256 _amount) public asActor {
        try lender.repay(_getAsset(), _amount, _getActor()) {
            // success
        } catch (bytes memory reason) {
            bool underflowError = checkError(reason, Panic.arithmeticPanic);

            t(!underflowError, "underflow error");
        }
    }
}
