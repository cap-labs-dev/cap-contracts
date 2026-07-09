// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMarket } from "../interfaces/IMarket.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { RewardLib } from "./RewardLib.sol";
import { ViewLib } from "./ViewLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LendLib
/// @author kexley
/// @notice Borrow, repay, liquidate, and market-creation logic.
library LendLib {
    using WadRayMath for uint256;

    /// @notice Mint unbacked stablecoin and increase the borrower's debt
    function borrow(IMarket.Storage storage $, address recipient, uint256 amount) external returns (uint256 borrowed) {
        if (amount == type(uint256).max) {
            amount = ViewLib.maxBorrowable($);
        }

        _validateBorrow($, amount);

        RewardLib.updateRewards($);

        borrowed = amount;
        uint256 scaledAmount = borrowed.rayDiv(ViewLib.index($));
        if (scaledAmount == 0) revert IMarket.InvalidAmount();
        $.scaledDebt += scaledAmount;

        IInterestRateModel($.irm).update(address(this));

        IStablecoin($.stablecoin).mintUnbacked(recipient, borrowed);

        emit IMarket.Borrow(msg.sender, recipient, borrowed);
    }

    /// @notice Repay by burning cUSD and reduce the borrower's debt
    function repay(IMarket.Storage storage $, uint256 amount) public returns (uint256 repaid) {
        RewardLib.updateRewards($);

        uint256 currentDebt = ViewLib.debt($);
        repaid = Math.min(amount, currentDebt);
        if (repaid == 0) revert IMarket.InvalidAmount();

        uint256 scaledRepaid = repaid.rayDiv(ViewLib.index($));
        if (scaledRepaid == 0) revert IMarket.InvalidAmount();
        $.scaledDebt -= scaledRepaid;

        IInterestRateModel($.irm).update(address(this));

        IStablecoin($.stablecoin).burnUnbacked(msg.sender, repaid);

        emit IMarket.Repay(msg.sender, repaid);
    }

    /// @notice Liquidate unhealthy debt by burning cUSD and returning collateral to slash
    function liquidate(IMarket.Storage storage $, address recipient, uint256 amount)
        external
        returns (uint256 repaid, uint256 assetsSlashed)
    {
        _validateLiquidate($);

        uint256 maxLiquidatable = ViewLib.maxLiquidatable($);
        if (amount > maxLiquidatable) amount = maxLiquidatable;

        repaid = repay($, amount);
        if (repaid == 0) return (repaid, assetsSlashed);

        uint256 assetsToSlash =
            (repaid * 10 ** $.decimals).rayDiv(ViewLib.getPrice($) * 1e27).rayMul(1e27 + ViewLib.bonus($));
        assetsSlashed = _slash($, assetsToSlash, recipient);
    }

    /// @notice Slash the junior tranche first, then the senior tranche for any shortfall
    function _slash(IMarket.Storage storage $, uint256 assetsToSlash, address recipient)
        internal
        returns (uint256 assetsSlashed)
    {
        if (assetsToSlash > 0) {
            assetsSlashed = ITranche($.juniorTranche).slash(assetsToSlash, recipient);
        }
        if (assetsToSlash > assetsSlashed) {
            assetsSlashed += ITranche($.seniorTranche).slash(assetsToSlash - assetsSlashed, recipient);
        }
    }

    /// @notice Validate the borrowing of a market
    function _validateBorrow(IMarket.Storage storage $, uint256 amount) internal view {
        if (amount == 0) revert IMarket.InvalidAmount();
        uint256 maxBorrowable = ViewLib.maxBorrowable($);
        if (amount > maxBorrowable) revert IMarket.InsufficientLiquidity();
    }

    /// @notice Validate the liquidation of a market
    function _validateLiquidate(IMarket.Storage storage $) internal view {
        uint256 currentDebt = ViewLib.debt($);
        uint256 totalCredit = ViewLib.totalCredit($);
        if (currentDebt < totalCredit.rayMul($.lt)) revert IMarket.Solvent();
    }
}
