// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMarket } from "../interfaces/IMarket.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { RewardLib } from "./RewardLib.sol";
import { ViewLib } from "./ViewLib.sol";

/// @title SetterLib
/// @author kexley
/// @notice Market configuration and admin setters.
library SetterLib {
    using WadRayMath for uint256;

    /// @notice Set the multiplier for a market
    function setMultiplier(IMarket.Storage storage $, uint256 multiplier) external {
        RewardLib.updateRewards($);
        uint256 currentDebt = $.scaledDebt.rayMul(ViewLib.index($));
        if (multiplier > 10e27 || multiplier < 0.1e27) revert IMarket.InvalidMultiplier();
        $.multiplier = multiplier;
        if (currentDebt > 0) $.scaledDebt = currentDebt.rayDiv(ViewLib.index($));
        emit IMarket.SetMultiplier(multiplier);
        $.lastSupplyIndex = ViewLib.supplyIndex($);
    }

    /// @notice Set the loan to value ratio for a market
    function setLtv(IMarket.Storage storage $, uint256 ltv) external {
        if (ltv + $.buffer > $.lt) revert IMarket.InvalidLtv();
        $.ltv = ltv;
        emit IMarket.SetLtv(ltv);
    }

    /// @notice Set the interest type for a market
    function setInterestType(IMarket.Storage storage $, bool _interestType) external {
        RewardLib.updateRewards($);
        uint256 currentDebt = $.scaledDebt.rayMul(ViewLib.index($));

        $.variable = _interestType;

        if (currentDebt > 0) $.scaledDebt = currentDebt.rayDiv(ViewLib.index($));
        $.lastSupplyIndex = ViewLib.supplyIndex($);
    }

    /// @notice Set the buffer for a market
    function setBuffer(IMarket.Storage storage $, uint256 buffer) external {
        $.buffer = buffer;
        emit IMarket.SetBuffer(buffer);
    }

    /// @notice Set the liquidation threshold for a market
    function setLt(IMarket.Storage storage $, uint256 lt) external {
        if (lt > 1e27) revert IMarket.InvalidLt();
        $.lt = lt;
        emit IMarket.SetLt(lt);
    }

    /// @notice Set the borrow cap for a market
    function setBorrowCap(IMarket.Storage storage $, uint256 borrowCap) external {
        $.borrowCap = borrowCap;
        emit IMarket.SetBorrowCap(borrowCap);
    }

    /// @notice Set the price oracle
    function setOracle(IMarket.Storage storage $, address oracle) external {
        $.oracle = oracle;
        emit IMarket.SetOracle(oracle);
    }

    /// @notice Set the target health factor used to size liquidations
    function setTargetHealth(IMarket.Storage storage $, uint256 targetHealth) external {
        $.targetHealth = targetHealth;
        emit IMarket.SetTargetHealth(targetHealth);
    }

    /// @notice Set the liquidation bonus curve parameters
    function setBonusConfig(IMarket.Storage storage $, uint256 kink, uint256 slope0, uint256 slope1) external {
        $.bonusKink = kink;
        $.bonusSlope0 = slope0;
        $.bonusSlope1 = slope1;
        emit IMarket.SetBonusConfig(kink, slope0, slope1);
    }

    /// @notice Set the stablecoin yield for a market
    function setStakedStablecoin(IMarket.Storage storage $, address stakedStablecoin) external {
        $.stakedStablecoin = stakedStablecoin;
        emit IMarket.SetStakedStablecoin(stakedStablecoin);
    }

    /// @notice Set the junior split for a market
    function setJuniorSplit(IMarket.Storage storage $, uint256 juniorSplit) external {
        if (juniorSplit > 1e27) revert IMarket.InvalidJuniorSplit();
        $.juniorSplit = juniorSplit;
        emit IMarket.SetJuniorSplit(juniorSplit);
    }

    /// @notice Set the senior tranche for a market
    function setSeniorTranche(IMarket.Storage storage $, address seniorTranche) external {
        if ($.seniorTranche != address(0)) revert IMarket.InvalidMarket();
        if (ITranche(seniorTranche).asset() != $.asset) revert IMarket.InvalidAsset();
        if (ITranche(seniorTranche).market() != address(this)) revert IMarket.InvalidMarket();
        $.seniorTranche = seniorTranche;
        emit IMarket.SetSeniorTranche(seniorTranche);
    }

    /// @notice Set the junior tranche for a market
    function setJuniorTranche(IMarket.Storage storage $, address juniorTranche) external {
        if ($.juniorTranche != address(0)) revert IMarket.InvalidMarket();
        if (ITranche(juniorTranche).asset() != $.asset) revert IMarket.InvalidAsset();
        if (ITranche(juniorTranche).market() != address(this)) revert IMarket.InvalidMarket();
        $.juniorTranche = juniorTranche;
        emit IMarket.SetJuniorTranche(juniorTranche);
    }
}
