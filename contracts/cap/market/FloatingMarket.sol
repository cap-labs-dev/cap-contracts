// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IBaseMarket } from "../../interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../utils/WadRayMath.sol";
import { BaseMarket } from "./BaseMarket.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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
    /// @dev The multiplier sits inside the liquidity index, so changing it would otherwise reprice
    /// every outstanding loan. Accrue first, then rewrite scaledDebt so
    /// `scaledDebt × index` is unchanged.
    ///
    /// Unchanged only to the nearest wei. `rayMul` steps by `index / RAY`, so once the index has
    /// grown past one ray not every debt is exactly representable and the reading can land a wei
    /// either side of where it was. The exactness {_floorReduction} gets is not available here:
    /// it works by deriving the settlement from the reduction, and there is nothing to settle
    /// against on a reindex, no cUSD minted or burned to match. Rounding to nearest is the closest
    /// available and the drift is not directional, so it cannot accumulate through repeated
    /// governance calls the way a one-sided rounding would.
    function setMarketMultiplier(uint256 multiplier) external override(BaseMarket, IBaseMarket) restricted {
        _chargePremium();
        uint256 debt = totalDebt();
        IInterestRateModel(irm()).updateMarketMultiplier(multiplier);
        lastLiquidityIndex = IInterestRateModel(irm()).liquidityIndex(address(this));
        if (debt > 0) {
            uint256 scaled = debt.rayDiv(index());
            if (scaled == 0) revert InvalidScaledAmount();
            scaledDebt = scaled;
        }
        emit SetMarketMultiplier(multiplier);
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
        uint256 debt = totalDebt();
        (uint256 remainingScaled, uint256 cleared) = _floorReduction(debt, _debtCheck(debt, amount));
        scaledDebt = remainingScaled;
        repaid = cleared;
        _repay(repaid);
    }

    /// @inheritdoc IFloatingMarket
    function liquidate(address recipient, uint256 amount)
        external
        restricted
        returns (uint256 repaid, uint256 assetsSlashed)
    {
        _chargePremium();
        uint256 debt = totalDebt();
        // floored up front but stored last, because the health gate and the cap inside
        // {_liquidate} are both measured off totalDebt and have to see the debt as it stands.
        // Clamping here too makes that cap a no-op, so `cleared` is what comes back as `repaid`
        (uint256 remainingScaled, uint256 cleared) = _floorReduction(debt, Math.min(amount, maxLiquidatable()));
        (repaid, assetsSlashed) = _liquidate(recipient, cleared);
        scaledDebt = remainingScaled;
    }

    /// @inheritdoc IFloatingMarket
    function chargePremium() external {
        _chargePremium();
    }

    /// @inheritdoc IFloatingMarket
    function writeOff() external restricted returns (uint256 amount) {
        _chargePremium();
        uint256 debt = totalDebt();
        (uint256 remainingScaled, uint256 cleared) = _floorReduction(debt, unrecoverableDebt());
        amount = cleared;
        // record against the pre-write-off debt, since {_writeOff} bounds itself by
        // {unrecoverableDebt} and that would read as nothing once scaledDebt has moved
        _writeOff(amount);
        scaledDebt = remainingScaled;
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

    /// @dev Work out the scaled debt that clears `target`, and how much debt that actually clears.
    ///
    /// `scaledDebt` is the source of truth and {totalDebt} is a rounded reading of it, so the debt
    /// a reduction clears is not `target` but whatever the reading falls by. Settling `target`
    /// conflated the two: `rayDiv` rounds half up, so the reading fell by more than the cUSD
    /// burned and left credit-backed supply with no debt behind it. At an index of 1.4907,
    /// repaying one wei cleared two.
    ///
    /// Rounding the other way does not fix it, it only moves the drift: the reading can only take
    /// values `index / RAY` apart, so once the index is above one ray most debt figures are not
    /// representable at all and no direction reconciles a lattice with an exact counter. Deriving
    /// the settlement from the reading's own movement is what makes them agree.
    ///
    /// Flooring is what bounds it: the reduction is at most `target * RAY / index`, so the reading
    /// falls by at most `target` and a caller is never charged above their request. A payment too
    /// small to move a whole scaled unit clears nothing, so it reverts rather than being taken for
    /// a no-op. Clearing in full is the one case flooring cannot express, since the floor can leave
    /// a scaled wei that reads back as dust debt nobody can retire: doing so would need more
    /// credit-backed supply burned than exists to decrement. It is zeroed outright instead.
    ///
    /// Returning `remainingScaled` rather than storing it leaves callers free to order their side
    /// effects, which both {liquidate} and {writeOff} need: each has a check that reads {totalDebt}
    /// and must run before the reduction lands.
    /// @param debt The debt before the reduction, as read by {totalDebt}
    /// @param target The debt to clear
    /// @return remainingScaled The scaled debt to store
    /// @return cleared The debt actually cleared, which is what must be settled against
    function _floorReduction(uint256 debt, uint256 target)
        internal
        view
        returns (uint256 remainingScaled, uint256 cleared)
    {
        if (target == 0) return (scaledDebt, 0);
        if (target >= debt) return (0, debt);

        uint256 currentIndex = index();
        // not rayDiv: every WadRayMath operation rounds half up, and half up here is the bug
        uint256 scaled = Math.mulDiv(target, WadRayMath.RAY, currentIndex);
        if (scaled == 0) revert InvalidScaledAmount();

        remainingScaled = scaledDebt - scaled;
        // rayMul, because this has to be the same expression {totalDebt} will report
        cleared = debt - remainingScaled.rayMul(currentIndex);
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
            previousUnderwriterIndex.rayMul(currentLiquidityIndex - previousLiquidityIndex)
        );
        underwriterPremium =
            scaledDebtAmount.rayMul(currentLiquidityIndex.rayMul(currentUnderwriterIndex - previousUnderwriterIndex));
    }
}
