// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import { RewardLib } from "./RewardLib.sol";
import { ViewLib } from "./ViewLib.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title LendLib
/// @author kexley
/// @notice Borrow, repay, liquidate, and market-creation logic.
library LendLib {
    using WadRayMath for uint256;
    using ViewLib for ILender.Storage;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Mint unbacked stablecoin and increase the borrower's debt
    function borrow(ILender.Storage storage $, bytes32 marketId, address recipient, uint256 amount)
        public
        returns (uint256 borrowed)
    {
        if (amount == type(uint256).max) {
            amount = $.maxBorrowable(marketId);
        }

        _validateBorrow($, marketId, msg.sender, amount);

        RewardLib.updateRewards($, marketId);

        ILender.Market storage market = $.market[marketId];
        borrowed = amount;
        uint256 scaledAmount = borrowed.rayDiv($.index(marketId));
        if (scaledAmount == 0) revert ILender.InvalidAmount();
        market.scaledDebt += scaledAmount;

        IInterestRateModel($.irm).update(marketId);

        IStablecoin($.stablecoin).mintUnbacked(recipient, borrowed);

        emit ILender.Borrow(marketId, msg.sender, recipient, borrowed);
    }

    /// @notice Repay by burning cUSD and reduce the borrower's debt
    function repay(ILender.Storage storage $, bytes32 marketId, uint256 amount) public returns (uint256 repaid) {
        RewardLib.updateRewards($, marketId);

        ILender.Market storage market = $.market[marketId];
        uint256 currentDebt = $.debt(marketId);
        repaid = Math.min(amount, currentDebt);
        if (repaid == 0) revert ILender.InvalidAmount();

        uint256 scaledRepaid = repaid.rayDiv($.index(marketId));
        if (scaledRepaid == 0) revert ILender.InvalidAmount();
        market.scaledDebt -= scaledRepaid;

        IInterestRateModel($.irm).update(marketId);

        IStablecoin($.stablecoin).burnUnbacked(msg.sender, repaid);

        emit ILender.Repay(marketId, msg.sender, repaid);
    }

    /// @notice Liquidate unhealthy debt by burning cUSD and slashing tranche collateral
    function liquidate(ILender.Storage storage $, bytes32 marketId, address recipient, uint256 amount)
        public
        returns (uint256 repaid, address assetLiquidated, uint256 assetsSlashed)
    {
        _validateLiquidate($, marketId);

        {
            uint256 maxLiquidatable = $.maxLiquidatable(marketId);
            if (amount > maxLiquidatable) amount = maxLiquidatable;
        }

        repaid = repay($, marketId, amount);
        if (repaid == 0) return (repaid, assetLiquidated, assetsSlashed);

        ILender.Market storage market = $.market[marketId];
        assetLiquidated = market.asset;
        uint256 assetsToSlash =
            (repaid * 10 ** market.decimals).rayDiv($.getPrice(marketId) * 1e27).rayMul(1e27 + $.getBonus(marketId));

        assetsSlashed = _slash(market, assetsToSlash, recipient);

        emit ILender.Liquidate(marketId, msg.sender, recipient, repaid, assetLiquidated, assetsSlashed);
    }

    /// @notice Slash the junior tranche first, then the senior tranche for any shortfall
    function _slash(ILender.Market storage market, uint256 assetsToSlash, address recipient)
        internal
        returns (uint256 assetsSlashed)
    {
        if (assetsToSlash > 0) {
            assetsSlashed = ITranche(market.juniorTranche).slash(assetsToSlash, recipient);
        }
        if (assetsToSlash > assetsSlashed) {
            assetsSlashed += ITranche(market.seniorTranche).slash(assetsToSlash - assetsSlashed, recipient);
        }
    }

    /// @notice Create a new market
    function createMarket(
        ILender.Storage storage $,
        address authority,
        string memory name,
        string memory symbol,
        address asset,
        uint256 ltv,
        address[] memory borrowers
    ) public returns (bytes32 marketId, address seniorTranche, address juniorTranche) {
        marketId = keccak256(abi.encode(name, symbol, asset));
        if ($.markets.contains(marketId)) revert ILender.MarketAlreadyExists();
        $.markets.add(marketId);

        seniorTranche = _deployTranche($, authority, marketId, name, symbol, asset);
        juniorTranche = _deployTranche($, authority, marketId, name, symbol, asset);

        ILender.Market storage market = $.market[marketId];
        market.asset = asset;
        market.decimals = IERC20Metadata(asset).decimals();
        market.seniorTranche = seniorTranche;
        market.juniorTranche = juniorTranche;
        market.variable = true;
        market.buffer = $.buffer;
        market.lt = $.lt;
        if (ltv + $.buffer > $.lt) revert ILender.InvalidLtv();
        market.ltv = ltv;
        for (uint256 i = 0; i < borrowers.length; ++i) {
            if (!market.borrowers.add(borrowers[i])) revert ILender.InvalidBorrower();
        }
        $.marketForTranche[seniorTranche] = marketId;
        $.marketForTranche[juniorTranche] = marketId;
        emit ILender.CreateMarket(marketId, seniorTranche, juniorTranche);
    }

    /// @notice Deploy a tranche beacon proxy for a market
    function _deployTranche(
        ILender.Storage storage $,
        address authority,
        bytes32 marketId,
        string memory name,
        string memory symbol,
        address asset
    ) internal returns (address tranche) {
        tranche = address(
            new BeaconProxy(
                $.trancheBeacon,
                abi.encodeCall(ITranche.initialize, (authority, marketId, name, symbol, asset, $.vault, $.irm))
            )
        );
    }

    /// @notice Validate the borrowing of a market
    function _validateBorrow(ILender.Storage storage $, bytes32 marketId, address caller, uint256 amount)
        internal
        view
    {
        ILender.Market storage market = $.market[marketId];
        if (!market.borrowers.contains(caller)) revert ILender.Unauthorized();
        if (amount == 0) revert ILender.InvalidAmount();
        uint256 maxBorrowable = $.maxBorrowable(marketId);
        if (amount > maxBorrowable) revert ILender.InsufficientLiquidity();
    }

    /// @notice Validate the liquidation of a market
    function _validateLiquidate(ILender.Storage storage $, bytes32 marketId) internal view {
        ILender.Market storage market = $.market[marketId];
        uint256 currentDebt = $.debt(marketId);
        uint256 totalCredit = $.totalCredit(marketId);
        if (currentDebt < totalCredit.rayMul(market.lt)) revert ILender.Solvent();
    }
}
