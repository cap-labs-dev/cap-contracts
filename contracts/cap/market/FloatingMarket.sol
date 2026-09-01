// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import { BaseMarket } from "./BaseMarket.sol";

/// @title FloatingMarket
/// @author kexley, Cap Labs
/// @notice Floating interest rate market
contract FloatingMarket layout at erc7201("cap.storage.FloatingMarket") is IFloatingMarket, BaseMarket {
    using WadRayMath for uint256;

    /// @dev Last cached liquidity index at premium charge
    uint256 private lastLiquidityIndex;

    /// @dev Last cached underwriter index at premium charge
    uint256 private lastUnderwriterIndex;

    /// @dev Timestamp of the last premium charge
    uint256 private lastPremiumUpdate;

    /// @dev Scaled outstanding debt
    uint256 private scaledDebt;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFloatingMarket
    function initialize(address _authority, address _registry, string memory _name) external initializer {
        __BaseMarket_init(_authority, _registry, _name);

        (lastLiquidityIndex, lastUnderwriterIndex) = premiumIndices();
        lastPremiumUpdate = block.timestamp;
    }

    /// @inheritdoc IBaseMarket
    function setMarketMultiplier(uint256 multiplier) external override(BaseMarket, IBaseMarket) restricted {
        _chargePremium();
        IInterestRateModel(irm()).setMarketMultiplier(multiplier);
        emit SetMarketMultiplier(multiplier);
        lastLiquidityIndex = IInterestRateModel(irm()).liquidityIndex(address(this));
    }

    /// @inheritdoc IFloatingMarket
    function borrow(address recipient, uint256 principal) external restricted returns (uint256 actualPrincipal) {
        _chargePremium();

        actualPrincipal = _creditCheck(availableCredit(), principal);
        uint256 scaledPrincipal = actualPrincipal.rayDiv(index());
        if (scaledPrincipal == 0) revert InvalidScaledAmount();
        scaledDebt += scaledPrincipal;

        _borrow(recipient, actualPrincipal);
    }

    /// @inheritdoc IFloatingMarket
    function repay(uint256 amount) external returns (uint256 repaid) {
        _chargePremium();
        repaid = _debtCheck(totalDebt(), amount);
        uint256 scaledRepaid = repaid.rayDiv(index());
        if (scaledRepaid == 0) revert InvalidScaledAmount();
        scaledDebt -= scaledRepaid;
        _repay(repaid);
    }

    /// @inheritdoc IFloatingMarket
    function liquidate(address recipient, uint256 amount)
        external
        restricted
        returns (uint256 repaid, uint256 assetsSlashed)
    {
        _chargePremium();
        (repaid, assetsSlashed) = _liquidate(recipient, amount);
        uint256 scaledRepaid = repaid.rayDiv(index());
        if (scaledRepaid == 0) revert InvalidScaledAmount();
        scaledDebt -= scaledRepaid;
    }

    /// @inheritdoc IFloatingMarket
    function chargePremium() external {
        _chargePremium();
    }

    /// @inheritdoc IBaseMarket
    function totalDebt() public view override(BaseMarket, IBaseMarket) returns (uint256 marketDebt) {
        marketDebt = scaledDebt.rayMul(index());
    }

    /// @inheritdoc IFloatingMarket
    function premium() external view returns (uint256 liquidityPremium, uint256 underwriterPremium) {
        if (scaledDebt > 0 && lastPremiumUpdate != block.timestamp) {
            (uint256 liquidityIndex, uint256 underwriterIndex) = premiumIndices();
            (liquidityPremium, underwriterPremium) =
                _premium(scaledDebt, lastLiquidityIndex, lastUnderwriterIndex, liquidityIndex, underwriterIndex);
        }
    }

    /// @inheritdoc IFloatingMarket
    function premiumIndices() public view returns (uint256 liquidityIndex, uint256 underwriterIndex) {
        if (lastPremiumUpdate == block.timestamp) return (lastLiquidityIndex, lastUnderwriterIndex);
        (liquidityIndex, underwriterIndex) = IInterestRateModel(irm()).indices(address(this));
    }

    /// @inheritdoc IFloatingMarket
    function index() public view returns (uint256 combinedIndex) {
        if (lastPremiumUpdate == block.timestamp) return lastLiquidityIndex.rayMul(lastUnderwriterIndex);
        (uint256 liquidityIndex, uint256 underwriterIndex) = premiumIndices();
        combinedIndex = liquidityIndex.rayMul(underwriterIndex);
    }

    /// @dev Accrue premiums for a market
    function _chargePremium() internal {
        if (lastPremiumUpdate == block.timestamp) return;

        (uint256 liquidityIndex, uint256 underwriterIndex) = premiumIndices();

        if (scaledDebt > 0) {
            (uint256 liquidityPremium, uint256 underwriterPremium) =
                _premium(scaledDebt, lastLiquidityIndex, lastUnderwriterIndex, liquidityIndex, underwriterIndex);
            _chargePremium(liquidityPremium, underwriterPremium);
        }

        lastLiquidityIndex = liquidityIndex;
        lastUnderwriterIndex = underwriterIndex;
        lastPremiumUpdate = block.timestamp;
    }

    /// @dev Calculate the liquidity and underwriter premiums
    /// @param scaledDebtAmount The scaled debt
    /// @param previousLiquidityIndex The last liquidity index
    /// @param previousUnderwriterIndex The last underwriter index
    /// @param currentLiquidityIndex The current liquidity index
    /// @param currentUnderwriterIndex The current underwriter index
    /// @return liquidityPremium The liquidity premium
    /// @return underwriterPremium The underwriter premium
    function _premium(
        uint256 scaledDebtAmount,
        uint256 previousLiquidityIndex,
        uint256 previousUnderwriterIndex,
        uint256 currentLiquidityIndex,
        uint256 currentUnderwriterIndex
    ) internal pure returns (uint256 liquidityPremium, uint256 underwriterPremium) {
        liquidityPremium = scaledDebtAmount.rayMul(
            previousLiquidityIndex.rayMul(currentLiquidityIndex - previousLiquidityIndex)
        );
        underwriterPremium =
            scaledDebtAmount.rayMul(currentLiquidityIndex.rayMul(currentUnderwriterIndex - previousUnderwriterIndex));
    }
}
