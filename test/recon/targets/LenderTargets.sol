// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { MockERC20 } from "@recon/MockERC20.sol";
import { Panic } from "@recon/Panic.sol";

import "contracts/lendingPool/Lender.sol";

import { BeforeAfter, OpType } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";

import { DebtToken } from "contracts/lendingPool/tokens/DebtToken.sol";

import { console2 } from "forge-std/console2.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

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

    function lender_liquidate_clamped(uint256 _amount) public {
        lender_liquidate(_getAsset(), _amount);
    }

    function lender_repay_clamped(uint256 _amount) public {
        lender_repay(_getAsset(), _amount);
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
            uint256 afterBorrowerDebt = DebtToken(_debtToken).balanceOf(_getActor());
            uint256 borrowerDebtDelta = afterBorrowerDebt - beforeBorrowerDebt;
            t(!capToken.paused() && !capToken.paused(_asset), "asset can be borrowed when it is paused");
            (,,,,, uint256 health) = lender.agent(_getActor());
            gt(health, RAY, "Borrower is unhealthy after borrowing");
            gt(
                DebtToken(_debtToken).balanceOf(_getActor()),
                beforeBorrowerDebt,
                "Borrower debt did not increase after borrowing"
            );
            if (_amount == type(uint256).max) {
                // Borrowing max amount
                eq(
                    MockERC20(_asset).balanceOf(_receiver),
                    beforeAssetBalance + beforeMaxBorrowable,
                    "Borrower asset balance should not increase after borrowing max amount"
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
        (,,,,, uint256 healthBefore) = ILender(address(lender)).agent(_getActor());

        try lender.initiateLiquidation(_getActor()) {
            if (healthBefore > 1e27) {
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
    function lender_liquidate(address _asset, uint256 _amount) public updateGhosts asActor {
        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 healthBefore) = lender.agent(_getActor());

        try lender.liquidate(_getActor(), _asset, _amount) {
            if (healthBefore > 1e27) {
                t(false, "agent should not be liquidatable with health > 1e27");
            }
            (,,,,, uint256 healthAfter) = lender.agent(_getActor());
            gt(healthAfter, healthBefore, "Liquidation did not improve health factor");
        } catch (bytes memory reason) {
            bool expectedError =
                checkError(reason, "ZeroAddressNotValid()") || checkError(reason, "InvalidBurnAmount()");
            bool expectedAsset;
            for (uint256 i = 0; i < capToken.assets().length; i++) {
                if (capToken.assets()[i] == _asset) {
                    expectedAsset = true;
                    break;
                }
            }
            if (!expectedError && expectedAsset) {
                gte(
                    totalDelegation * lender.emergencyLiquidationThreshold() / totalDebt,
                    RAY,
                    "Emergency liquidations is not available when emergency health is below 1e27"
                );
            }
        }
    }

    function lender_pauseAsset(address _asset, bool _pause) public updateGhosts asAdmin {
        lender.pauseAsset(_asset, _pause);
    }

    /// @dev Property: realizeInterest should only revert with ZeroRealization if paused or totalUnrealizedInterest == 0, otherwise should always update the realization value
    function lender_realizeInterest(address _asset) public updateGhostsWithType(OpType.REALIZE_INTEREST) asActor {
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

    function lender_realizeRestakerInterest(address _asset)
        public
        updateGhostsWithType(OpType.REALIZE_INTEREST)
        asActor
    {
        lender.realizeRestakerInterest(_getActor(), _asset);
    }

    function lender_removeAsset(address _asset) public updateGhosts asAdmin {
        lender.removeAsset(_asset);
    }

    /// @dev Property: Repay should never revert due to under/overflow
    function lender_repay(address _asset, uint256 _amount) public asActor {
        try lender.repay(_asset, _amount, _getActor()) {
            // success
        } catch (bytes memory reason) {
            bool underflowError = checkError(reason, Panic.arithmeticPanic);

            t(!underflowError, "underflow error");
        }
    }
}
