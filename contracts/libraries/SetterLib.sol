// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ILender } from "../interfaces/ILender.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { RewardLib } from "./RewardLib.sol";
import { ViewLib } from "./ViewLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title SetterLib
/// @author kexley
/// @notice Market configuration and admin setters.
library SetterLib {
    using WadRayMath for uint256;
    using ViewLib for ILender.Storage;
    using EnumerableSet for EnumerableSet.AddressSet;

    event SetLtv(bytes32 marketId, uint256 ltv);
    event AddBorrower(bytes32 marketId, address borrower);
    event RemoveBorrower(bytes32 marketId, address borrower);
    event SetInterestType(bytes32 marketId, bool supplyVariable);
    event SetMultiplier(bytes32 marketId, uint256 multiplier);
    event SetDefaultBuffer(uint256 buffer);
    event SetDefaultLt(uint256 lt);
    event SetBuffer(bytes32 marketId, uint256 buffer);
    event SetLt(bytes32 marketId, uint256 lt);
    event SetBorrowCap(bytes32 marketId, uint256 borrowCap);
    event SetMultiplierLimits(uint256 min, uint256 max);
    event SetOracle(address oracle);
    event SetTargetHealth(uint256 targetHealth);
    event SetBonusConfig(uint256 kink, uint256 slope0, uint256 slope1);
    event SetJuniorSplit(bytes32 marketId, uint256 juniorSplit);
    event SetStcUSD(address stcUSD);

    /// @notice Set the loan to value ratio for a market
    function setLtv(ILender.Storage storage $, bytes32 marketId, uint256 ltv) public {
        ILender.Market storage market = $.market[marketId];
        if (ltv + market.buffer > market.lt) revert ILender.InvalidLtv();
        market.ltv = ltv;
        emit SetLtv(marketId, ltv);
    }

    /// @notice Add a borrower to a market
    function addBorrower(ILender.Storage storage $, bytes32 marketId, address borrower) public {
        ILender.Market storage market = $.market[marketId];
        market.borrowers.add(borrower);
        emit AddBorrower(marketId, borrower);
    }

    /// @notice Remove a borrower from a market
    function removeBorrower(ILender.Storage storage $, bytes32 marketId, address borrower) public {
        ILender.Market storage market = $.market[marketId];
        market.borrowers.remove(borrower);
        emit RemoveBorrower(marketId, borrower);
    }

    /// @notice Switch a market between variable and fixed supply rates
    function setInterestType(ILender.Storage storage $, bytes32 marketId, bool variable) public {
        RewardLib.updateRewards($, marketId);
        uint256 currentDebt = $.debt(marketId);

        ILender.Market storage market = $.market[marketId];
        market.variable = variable;

        if (currentDebt > 0) market.scaledDebt = currentDebt.rayDiv($.index(marketId));
        RewardLib.updateSupplyIndex($, marketId);

        emit SetInterestType(marketId, market.variable);
    }

    /// @notice Set the supply rate multiplier for a market
    function setMultiplier(ILender.Storage storage $, bytes32 marketId, uint256 multiplier) public {
        if (multiplier < $.minMultiplier || multiplier > $.maxMultiplier) revert ILender.InvalidMultiplier();

        RewardLib.updateRewards($, marketId);

        uint256 currentDebt = $.debt(marketId);
        ILender.Market storage market = $.market[marketId];
        market.multiplier = multiplier;
        if (currentDebt > 0) market.scaledDebt = currentDebt.rayDiv($.index(marketId));
        RewardLib.updateSupplyIndex($, marketId);
        emit SetMultiplier(marketId, multiplier);
    }

    /// @notice Set the default buffer
    function setDefaultBuffer(ILender.Storage storage $, uint256 buffer) public {
        $.buffer = buffer;
        emit SetDefaultBuffer(buffer);
    }

    /// @notice Set the default liquidation threshold
    function setDefaultLt(ILender.Storage storage $, uint256 lt) public {
        $.lt = lt;
        emit SetDefaultLt(lt);
    }

    /// @notice Set the buffer for a market
    function setBuffer(ILender.Storage storage $, bytes32 marketId, uint256 buffer) public {
        $.market[marketId].buffer = buffer;
        emit SetBuffer(marketId, buffer);
    }

    /// @notice Set the liquidation threshold for a market
    function setLt(ILender.Storage storage $, bytes32 marketId, uint256 lt) public {
        $.market[marketId].lt = lt;
        emit SetLt(marketId, lt);
    }

    /// @notice Set the borrow cap for a market
    function setBorrowCap(ILender.Storage storage $, bytes32 marketId, uint256 borrowCap) public {
        $.market[marketId].borrowCap = borrowCap;
        emit SetBorrowCap(marketId, borrowCap);
    }

    /// @notice Set the minimum and maximum supply rate multipliers
    function setMultiplierLimits(ILender.Storage storage $, uint256 min, uint256 max) public {
        $.minMultiplier = min;
        $.maxMultiplier = max;
        emit SetMultiplierLimits(min, max);
    }

    /// @notice Set the price oracle
    function setOracle(ILender.Storage storage $, address oracle) public {
        $.oracle = oracle;
        emit SetOracle(oracle);
    }

    /// @notice Set the target health factor used to size liquidations
    function setTargetHealth(ILender.Storage storage $, uint256 targetHealth) public {
        $.targetHealth = targetHealth;
        emit SetTargetHealth(targetHealth);
    }

    /// @notice Set the liquidation bonus curve parameters
    function setBonusConfig(ILender.Storage storage $, uint256 kink, uint256 slope0, uint256 slope1) public {
        $.bonusKink = kink;
        $.bonusSlope0 = slope0;
        $.bonusSlope1 = slope1;
        emit SetBonusConfig(kink, slope0, slope1);
    }

    /// @notice Set the staked cUSD recipient of supply rewards
    function setStcUSD(ILender.Storage storage $, address stcUSD) public {
        $.stcUSD = stcUSD;
        emit SetStcUSD(stcUSD);
    }

    /// @notice Set the junior split for a market (tranche only)
    function setJuniorSplit(ILender.Storage storage $, bytes32 marketId, uint256 juniorSplit) public {
        ILender.Market storage market = $.market[marketId];
        if (msg.sender != market.juniorTranche && msg.sender != market.seniorTranche) {
            revert ILender.Unauthorized();
        }
        if (juniorSplit > 1e27) revert ILender.InvalidJuniorSplit();
        market.juniorSplit = juniorSplit;
        emit SetJuniorSplit(marketId, juniorSplit);
    }
}
