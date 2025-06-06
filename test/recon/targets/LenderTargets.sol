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
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

abstract contract LenderTargets is BaseTargetFunctions, Properties {
    uint256 constant RAY = 1e27;

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
    function lender_borrow(address _asset, uint256 _amount, address _receiver)
        public
        updateGhostsWithType(OpType.BORROW)
        asAgent
    {
        uint256 beforeAssetBalance = MockERC20(_asset).balanceOf(_receiver);
        (,, address _debtToken,,,,) = lender.reservesData(_asset);
        uint256 beforeBorrowerDebt = DebtToken(_debtToken).balanceOf(agent);
        uint256 beforeTotalBorrows = capToken.totalBorrows(_asset);
        vm.prank(agent);
        try lender.borrow(_asset, _amount, _receiver) {
            bool isProtocolPaused = capToken.paused();
            bool isAssetPaused = capToken.paused(_asset);
            t(!isProtocolPaused && !isAssetPaused, "asset can be borrowed when it is paused");
            (,,,,, uint256 health) = lender.agent(agent);
            gt(health, RAY, "Borrower is unhealthy after borrowing");
            eq(
                capToken.totalBorrows(_asset),
                beforeTotalBorrows + _amount,
                "Total borrows did not increase after borrowing"
            );
            gt(
                DebtToken(_debtToken).balanceOf(agent),
                beforeBorrowerDebt,
                "Borrower debt did not increase after borrowing"
            );
            eq(
                MockERC20(_asset).balanceOf(_receiver),
                beforeAssetBalance + _amount,
                "Borrower asset balance did not increase after borrowing"
            );
        } catch (bytes memory err) { }
    }

    function lender_cancelLiquidation(address _agent) public updateGhosts asActor {
        lender.cancelLiquidation(_agent);
    }

    function lender_initiateLiquidation(address _agent) public updateGhosts asActor {
        lender.initiateLiquidation(_agent);
    }

    /// @dev Property: agent should not be liquidatable with health > 1e27
    function lender_liquidate(address _agent, address _asset, uint256 _amount) public updateGhosts asActor {
        (,,,,, uint256 healthBefore) = ILender(address(lender)).agent(agent);

        try lender.liquidate(_agent, _asset, _amount) {
            if (healthBefore > 1e27) {
                t(false, "agent should not be liquidatable with health > 1e27");
            }
        } catch { }
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

    function lender_realizeRestakerInterest(address _agent, address _asset)
        public
        updateGhostsWithType(OpType.REALIZE_INTEREST)
        asActor
    {
        lender.realizeRestakerInterest(_agent, _asset);
    }

    function lender_removeAsset(address _asset) public updateGhosts asAdmin {
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
