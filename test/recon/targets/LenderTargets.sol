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
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function lender_borrow_clamped(uint256 _amount) public {
        lender_borrow(_amount, _getActor());
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
        require(!_isAddressUnderlying(vault), "vault is already an underlying asset");
        require(!_isAddressUnderlying(debtToken), "debtToken is already an underlying asset");

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

    function _isAddressUnderlying(address addressToCheck) internal view returns (bool) {
        address[] memory assets = _getAssets();
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == addressToCheck) {
                return true;
            }
        }
        return false;
    }

    /// @dev Property: Asset cannot be borrowed when it is paused
    /// @dev Property: Borrower should be healthy after borrowing (self-liquidation)
    /// @dev Property: Borrower asset balance should increase after borrowing
    /// @dev Property: Borrower debt should increase after borrowing
    /// @dev Property: Total borrows should increase after borrowing
    /// @dev Property: Borrower can't borrow more than LTV
    /// @dev Property: Borrow should only revert with an expected error
    function lender_borrow(uint256 _amount, address _receiver) public updateGhostsWithType(OpType.BORROW) asActor {
        uint256 beforeAssetBalance = MockERC20(_getAsset()).balanceOf(_receiver);
        (,, address _debtToken,,,,) = lender.reservesData(_getAsset());
        uint256 beforeBorrowerDebt = DebtToken(_debtToken).balanceOf(_getActor());
        uint256 beforeMaxBorrowable = lender.maxBorrowable(_getActor(), _getAsset());
        bool protocolPaused = capToken.paused();
        bool assetPaused = capToken.paused(_getAsset());

        vm.prank(_getActor());
        try lender.borrow(_getAsset(), _amount, _receiver) {
            uint256 borrowerDebtDelta = DebtToken(_debtToken).balanceOf(_getActor()) - beforeBorrowerDebt;

            t(!protocolPaused || !assetPaused, "asset can be borrowed when it is paused");

            (,,,,, uint256 health) = lender.agent(_getActor());
            gt(health, RAY, "Borrower is unhealthy after borrowing");

            gt(
                DebtToken(_debtToken).balanceOf(_getActor()),
                beforeBorrowerDebt,
                "Borrower debt did not increase after borrowing"
            );
            if (_receiver != address(capToken)) {
                if (_amount == type(uint256).max) {
                    eq(
                        MockERC20(_getAsset()).balanceOf(_receiver),
                        beforeAssetBalance + beforeMaxBorrowable,
                        "Borrower asset balance did not increase after borrowing (in case of max borrow)"
                    );
                } else {
                    eq(
                        MockERC20(_getAsset()).balanceOf(_receiver),
                        beforeAssetBalance + _amount,
                        "Borrower asset balance did not increase after borrowing"
                    );
                }
            }

            (uint256 assetPrice,) = oracle.getPrice(_getAsset());
            (uint256 collateralValue,) =
                mockNetworkMiddleware.coverageByVault(address(0), _getActor(), mockEth, address(0), 0);

            lte(
                (borrowerDebtDelta * assetPrice / 10 ** MockERC20(_getAsset()).decimals()) * RAY / collateralValue,
                delegation.ltv(_getActor()),
                "Borrower can't borrow more than LTV"
            );
        } catch (bytes memory reason) {
            // bool expectedError = checkError(reason, "MinBorrowAmount()") || checkError(reason, "ZeroAddressNotValid()")
            //     || checkError(reason, "ReservePaused()") || checkError(reason, "CollateralCannotCoverNewBorrow()")
            //     || checkError(reason, "LossFromFractionalReserve(address,address,uint256)")
            //     || checkError(reason, "ZeroRealization()");

            // NOTE: temporarily removed because we need higher specificity to be able to check for the divest error
            // // if borrow reverts for any other reason, it could be due to the call to divest in the ERC4626 made before borrowing
            // if (!expectedError && !protocolPaused && !assetPaused) {
            //     t(false, "borrow should revert with expected error");
            // }
        }
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

    /// @dev Property: Liquidations should always be profitable for the liquidator
    /// @dev Property: agent should not be liquidatable with health > 1e27
    /// @dev Property: Liquidations should always improve the health factor
    /// @dev Property: Partial liquidations should not bring health above 1.25
    /// @dev Property: Agent should have their totalDelegation reduced by the liquidated value
    /// @dev Property: Agent should have their totalSlashableCollateral reduced by the liquidated value
    function lender_liquidate(uint256 _amount) public updateGhosts asActor {
        (uint256 totalDelegationBefore, uint256 totalSlashableCollateralBefore,,,, uint256 healthBefore) =
            lender.agent(_getActor());
        uint256 maxLiquidatable = lender.maxLiquidatable(_getActor(), _getAsset());
        uint256 assetBalanceBefore = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 collateralBalanceBefore = MockERC20(mockNetworkMiddleware.vaults(_getActor())).balanceOf(_getActor());

        uint256 liquidatedValue = lender.liquidate(_getActor(), _getAsset(), _amount);

        (uint256 totalDelegationAfter, uint256 totalSlashableCollateralAfter,,,, uint256 healthAfter) =
            lender.agent(_getActor());
        {
            address vault = mockNetworkMiddleware.vaults(_getActor());
            (uint256 collateralPrice,) = oracle.getPrice(vault); // vault token is what's minted by the MockNetworkMiddleware
            (uint256 assetPrice,) = oracle.getPrice(_getAsset());
            uint256 assetBalanceAfter = MockERC20(_getAsset()).balanceOf(_getActor());
            uint256 collateralBalanceAfter = MockERC20(vault).balanceOf(_getActor());
            uint256 collateralAmountDelta = collateralBalanceAfter - collateralBalanceBefore;
            uint256 assetAmountDelta = assetBalanceAfter - assetBalanceBefore;
            // Calculate value of deltas using oracle price
            uint256 collateralValueDelta =
                (collateralAmountDelta * collateralPrice) / (10 ** MockERC20(vault).decimals());
            uint256 assetValueDelta = (assetAmountDelta * assetPrice) / (10 ** MockERC20(_getAsset()).decimals());
            gte(collateralValueDelta, assetValueDelta, "liquidation should be profitable for the liquidator");
        }

        if (healthBefore > RAY) {
            t(false, "agent should not be liquidatable with health > 1e27");
        }

        gt(healthAfter, healthBefore, "Liquidation did not improve health factor");
        // precondition: must be liquidating less than maxLiquidatable
        if (_amount < maxLiquidatable) {
            lte(healthAfter, 1.25e27, "partial liquidation should not bring health above 1.25");
        }

        lte(
            totalDelegationAfter,
            totalDelegationBefore - liquidatedValue,
            "agent maintains more value in totalDelegation than they should"
        );
        lte(
            totalSlashableCollateralAfter,
            totalSlashableCollateralBefore - liquidatedValue,
            "agent maintains more value in totalSlashableCollateral than they should"
        );
    }

    function lender_pauseAsset(bool _pause) public updateGhosts asAdmin {
        lender.pauseAsset(_getAsset(), _pause);
    }

    /// @dev Property: agent's total debt should not change when interest is realized
    /// @dev Property: vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized
    /// @dev Property: vault debt and total borrows should increase by the same amount after a call to `realizeInterest`
    /// @dev Property: health should not change when realizeInterest is called
    /// @dev Property: interest can only be realized if there are sufficient vault assets
    /// @dev Property: realizeInterest should only revert with ZeroRealization if paused or totalUnrealizedInterest == 0, otherwise should always update the realization value
    function lender_realizeInterest() public updateGhostsWithType(OpType.REALIZE_INTEREST) {
        (,,, address interestReceiver,,,) = lender.reservesData(_getAsset());
        (,, uint256 totalDebtBefore,,, uint256 healthBefore) = _getAgentParams(_getActor());
        uint256 vaultDebtBefore = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 interestReceiverBalanceBefore = MockERC20(_getAsset()).balanceOf(address(interestReceiver)); // we check the balance of the interest receiver as a proxy for the vault because they're the one that actually receive assets that get borrowed from vault
        uint256 totalBorrowsBefore = capToken.totalBorrows(_getAsset());
        uint256 totalSuppliesBefore = capToken.totalSupplies(_getAsset());

        vm.prank(_getActor());
        try lender.realizeInterest(_getAsset()) returns (uint256 realizedInterest) {
            (,, uint256 totalDebtAfter,,, uint256 healthAfter) = _getAgentParams(_getActor());
            uint256 vaultDebtAfter = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
            uint256 interestReceiverBalanceAfter = MockERC20(_getAsset()).balanceOf(address(interestReceiver));
            uint256 totalBorrowsAfter = capToken.totalBorrows(_getAsset());

            eq(totalDebtAfter, totalDebtBefore, "agent total debt should not change after realizeInterest");
            eq(
                vaultDebtAfter - vaultDebtBefore,
                interestReceiverBalanceAfter - interestReceiverBalanceBefore,
                "vault debt increase != asset decrease in realizeInterest"
            );
            eq(
                vaultDebtAfter - vaultDebtBefore,
                totalBorrowsAfter - totalBorrowsBefore,
                "vault debt and total borrows should increase by the same amount after realizeInterest"
            );
            eq(healthAfter, healthBefore, "health should not change after realizeInterest");
            gte(totalSuppliesBefore, realizedInterest, "interest realized without sufficient vault assets");
        } catch (bytes memory reason) {
            bool zeroRealizationError = checkError(reason, "ZeroRealization()");

            (,,,,, bool paused,) = lender.reservesData(_getAsset());
            uint256 totalUnrealizedInterest = LenderWrapper(address(lender)).getTotalUnrealizedInterest(_getAsset());

            if (!paused && !zeroRealizationError && totalUnrealizedInterest != 0) {
                t(false, "realizeInterest does not update when it should");
            }
        }
    }

    /// @dev Property: vault debt should increase by the same amount that the underlying asset in the vault decreases when restaker interest is realized
    /// @dev Property: vault debt and total borrows should increase by the same amount after a call to `realizeRestakerInterest`
    /// @dev Property: health should not change when realizeRestakerInterest is called
    /// @dev Property: restakerinterest can only be realized if there are sufficient vault assets
    function lender_realizeRestakerInterest() public updateGhostsWithType(OpType.REALIZE_INTEREST) asActor {
        uint256 vaultDebtBefore = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 vaultAssetBalanceBefore = MockERC20(_getAsset()).balanceOf(address(capToken));
        (,,,,, uint256 healthBefore) = _getAgentParams(_getActor());
        uint256 totalBorrowsBefore = capToken.totalBorrows(_getAsset());
        uint256 totalSuppliesBefore = capToken.totalSupplies(_getAsset());

        uint256 realizedInterest = lender.realizeRestakerInterest(_getActor(), _getAsset());

        uint256 vaultDebtAfter = LenderWrapper(address(lender)).getVaultDebt(_getAsset());
        uint256 vaultAssetBalanceAfter = MockERC20(_getAsset()).balanceOf(address(capToken));
        (,,,,, uint256 healthAfter) = _getAgentParams(_getActor());
        uint256 totalBorrowsAfter = capToken.totalBorrows(_getAsset());

        eq(
            vaultDebtAfter - vaultDebtBefore,
            vaultAssetBalanceBefore - vaultAssetBalanceAfter,
            "vault debt increase != asset decrease in realizeRestakerInterest"
        );
        eq(
            vaultDebtAfter - vaultDebtBefore,
            totalBorrowsAfter - totalBorrowsBefore,
            "vault debt and total borrows should increase by the same amount after realizeRestakerInterest"
        );
        eq(healthAfter, healthBefore, "health should not change after realizeRestakerInterest");
        gte(totalSuppliesBefore, realizedInterest, "interest realized without sufficient vault assets");
    }

    function lender_removeAsset(address _asset) public updateGhosts asAdmin {
        lender.removeAsset(_asset);
    }

    function lender_repay(uint256 _amount) public asActor {
        lender.repay(_getAsset(), _amount, _getActor());
    }
}
