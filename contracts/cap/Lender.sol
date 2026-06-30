// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IInverseInterestRateModel } from "../interfaces/IInverseInterestRateModel.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IRewarder } from "../interfaces/IRewarder.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { LenderStorageUtils } from "../storage/LenderStorageUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Lender
/// @author kexley
/// @notice The Lender is the central contract for the Cap protocol. It is responsible for managing the markets and the underwriters.
contract Lender is ILender, AccessManagedUpgradeable, LenderStorageUtils, UUPSUpgradeable {
    using WadRayMath for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Initialize the Lender
    /// @param _authority The authority address
    /// @param _stablecoin The stablecoin address
    /// @param _underwriterBeacon The underwriter beacon address
    /// @param _oracle The oracle address
    /// @param _rewarder The rewarder address
    /// @param _vault The vault address
    /// @param _irm The interest rate model address
    function initialize(
        address _authority,
        address _stablecoin,
        address _underwriterBeacon,
        address _oracle,
        address _rewarder,
        address _vault,
        address _irm
    ) external initializer {
        Storage storage $ = getLenderStorage();
        __AccessManaged_init(_authority);
        $.stablecoin = _stablecoin;
        $.underwriterBeacon = _underwriterBeacon;
        $.oracle = _oracle;
        $.rewarder = _rewarder;
        $.vault = _vault;
        $.irm = _irm;
    }

    /// @notice Mint unbacked stablecoin and increase the borrower's debt
    /// @param marketId The ID of the market
    /// @param recipient The recipient of the minted stablecoin
    /// @param amount The amount to borrow
    function borrow(bytes32 marketId, address recipient, uint256 amount) external returns (uint256 borrowed) {
        if (amount == type(uint256).max) {
            amount = maxBorrowable(marketId);
        }

        _validateBorrow(marketId, msg.sender, amount);

        Storage storage $ = getLenderStorage();
        IRewarder($.rewarder).updateRewards(marketId);

        Market storage market = $.market[marketId];
        borrowed = amount;
        uint256 scaledAmount = borrowed.rayDiv(index(marketId));
        if (scaledAmount == 0) revert InvalidAmount();
        market.scaledDebt += scaledAmount;

        IInverseInterestRateModel($.irm).update(marketId);

        IStablecoin($.stablecoin).mintUnbacked(recipient, borrowed);

        emit Borrow(marketId, msg.sender, recipient, borrowed);
    }

    /// @notice Repay by burning cUSD and reduce the borrower's debt
    /// @param marketId The ID of the market
    /// @param amount The amount of cUSD to repay
    /// @return repaid The amount of cUSD actually repaid
    function repay(bytes32 marketId, uint256 amount) public returns (uint256 repaid) {
        Storage storage $ = getLenderStorage();
        IRewarder($.rewarder).updateRewards(marketId);

        Market storage market = $.market[marketId];
        uint256 debt = debt(marketId);
        repaid = Math.min(amount, debt);
        if (repaid == 0) revert InvalidAmount();

        uint256 scaledRepaid = repaid.rayDiv(index(marketId));
        if (scaledRepaid == 0) revert InvalidAmount();
        market.scaledDebt -= scaledRepaid;

        IInverseInterestRateModel($.irm).update(marketId);

        IStablecoin($.stablecoin).burnUnbacked(msg.sender, repaid);

        emit Repay(marketId, msg.sender, repaid);
    }

    /// @notice Liquidate unhealthy debt by burning cUSD and slashing underwriter collateral
    /// @dev Junior tranche is slashed first, then senior. Anyone can liquidate an unhealthy market.
    /// @param marketId The ID of the market
    /// @param amount The amount of cUSD the liquidator burns
    /// @param recipient The recipient of the liquidated assets
    /// @return repaid The amount of cUSD burned
    /// @return assetLiquidated The asset that was liquidated
    function liquidate(bytes32 marketId, address recipient, uint256 amount)
        external
        returns (uint256 repaid, address assetLiquidated, uint256 assetsSlashed)
    {
        Storage storage $ = getLenderStorage();
        _validateLiquidate(marketId);

        uint256 maxLiquidatable = maxLiquidatable(marketId);
        if (amount > maxLiquidatable) amount = maxLiquidatable;

        repaid = repay(marketId, amount);

        if (repaid > 0) {
            Market storage market = $.market[marketId];
            assetLiquidated = market.asset;
            uint256 assetsToSlash =
                (repaid * 10 ** market.decimals).rayDiv(getPrice(marketId) * 1e27).rayMul(1e27 + getBonus(marketId));

            if (assetsToSlash > 0) {
                assetsSlashed = IUnderwriter(market.juniorUnderwriter).slash(assetsToSlash, recipient);
            }
            if (assetsToSlash > assetsSlashed) {
                assetsSlashed += IUnderwriter(market.seniorUnderwriter).slash(assetsToSlash - assetsSlashed, recipient);
            }

            emit Liquidate(marketId, msg.sender, recipient, repaid, assetLiquidated, assetsSlashed);
        }
    }

    /// @notice Create a new market
    /// @param name The name of the market
    /// @param symbol The symbol of the market
    /// @param asset The asset to underwrite
    /// @param manager The address of the manager
    /// @param ltv The loan to value ratio for the market
    /// @param borrowers The addresses of the borrowers
    /// @return marketId The identifier for the new market
    /// @return seniorUnderwriter The address of the senior underwriter
    /// @return juniorUnderwriter The address of the junior underwriter
    function createMarket(
        string memory name,
        string memory symbol,
        address asset,
        address manager,
        uint256 ltv,
        address[] calldata borrowers
    ) external returns (bytes32 marketId, address seniorUnderwriter, address juniorUnderwriter) {
        Storage storage $ = getLenderStorage();
        bytes32 marketId = keccak256(abi.encode(name, symbol, asset, manager));
        if ($.markets.contains(marketId)) revert MarketAlreadyExists();
        $.markets.add(marketId);

        seniorUnderwriter = address(
            new BeaconProxy(
                $.underwriterBeacon,
                abi.encodeCall(
                    IUnderwriter.initialize, (marketId, name, symbol, asset, manager, $.vault, $.rewarder, $.irm)
                )
            )
        );
        juniorUnderwriter = address(
            new BeaconProxy(
                $.underwriterBeacon,
                abi.encodeCall(
                    IUnderwriter.initialize, (marketId, name, symbol, asset, manager, $.vault, $.rewarder, $.irm)
                )
            )
        );

        Market storage market = $.market[marketId];
        market.asset = asset;
        market.decimals = IERC20Metadata(asset).decimals();
        market.manager = manager;
        market.seniorUnderwriter = seniorUnderwriter;
        market.juniorUnderwriter = juniorUnderwriter;
        market.variable = true;
        market.buffer = $.buffer;
        market.lt = $.lt;
        if (ltv + $.buffer > $.lt) revert InvalidLtv();
        market.ltv = ltv;
        for (uint256 i = 0; i < borrowers.length; ++i) {
            if (!market.borrowers.add(borrowers[i])) revert InvalidBorrower();
        }
        emit CreateMarket(marketId);
    }

    /// @notice Set the loan to value ratio for the borrower
    /// @dev Callable by the market manager
    /// @param ltv The new loan to value ratio
    function setLtv(bytes32 marketId, uint256 ltv) external {
        Market storage market = getLenderStorage().market[marketId];
        if (msg.sender != market.manager) revert Unauthorized();

        if (ltv + market.buffer > market.lt) revert InvalidLtv();
        market.ltv = ltv;
        emit SetLtv(marketId, ltv);
    }

    /// @notice Set the borrower for the underwriter
    /// @dev Callable by the market manager
    /// @param borrower The new borrower address
    function addBorrower(bytes32 marketId, address borrower) external {
        Market storage market = getLenderStorage().market[marketId];
        if (msg.sender != market.manager) revert Unauthorized();

        market.borrowers.add(borrower);
        emit AddBorrower(marketId, borrower);
    }

    /// @notice Remove a borrower from the underwriter
    /// @dev Callable by the market manager
    /// @param borrower The borrower to remove
    function removeBorrower(bytes32 marketId, address borrower) external {
        Market storage market = getLenderStorage().market[marketId];
        if (msg.sender != market.manager) revert Unauthorized();

        market.borrowers.remove(borrower);
        emit RemoveBorrower(marketId, borrower);
    }

    /// @notice Set the manager for the market
    /// @dev Callable by the market manager
    /// @param manager The new manager address
    function setManager(bytes32 marketId, address manager) external {
        Market storage market = getLenderStorage().market[marketId];
        if (msg.sender != market.manager) revert Unauthorized();
        if (manager == address(0)) revert InvalidManager();

        market.manager = manager;
        emit SetManager(marketId, manager);
    }

    /// @notice Switch a market between variable and fixed supply rates
    /// @dev Callable by the market manager
    /// @param marketId The ID of the market
    /// @param variable True for variable supply rate, false for fixed
    function setInterestType(bytes32 marketId, bool variable) external restricted {
        Storage storage $ = getLenderStorage();

        IRewarder($.rewarder).updateRewards(marketId);
        uint256 debt = debt(marketId);

        Market storage market = $.market[marketId];
        market.variable = variable;

        if (debt > 0) market.scaledDebt = debt.rayDiv(index(marketId));
        IRewarder($.rewarder).updateSupplyIndex(marketId);

        emit SetInterestType(marketId, market.variable);
    }

    /// @notice Set the supply rate multiplier for a market
    /// @param marketId The ID of the market
    /// @param multiplier The new multiplier
    function setMultiplier(bytes32 marketId, uint256 multiplier) external restricted {
        Storage storage $ = getLenderStorage();
        if (multiplier < $.minMultiplier || multiplier > $.maxMultiplier) revert InvalidMultiplier();

        IRewarder($.rewarder).updateRewards(marketId);

        uint256 debt = debt(marketId);
        Market storage market = $.market[marketId];
        market.multiplier = multiplier;
        if (debt > 0) market.scaledDebt = debt.rayDiv(index(marketId));
        IRewarder($.rewarder).updateSupplyIndex(marketId);
        emit SetMultiplier(marketId, multiplier);
    }

    /// @notice Set the default buffer
    /// @param buffer The new default buffer
    function setDefaultBuffer(uint256 buffer) external restricted {
        getLenderStorage().buffer = buffer;
        emit SetDefaultBuffer(buffer);
    }

    /// @notice Set the default liquidation threshold
    /// @param lt The new default liquidation threshold
    function setDefaultLt(uint256 lt) external restricted {
        getLenderStorage().lt = lt;
        emit SetDefaultLt(lt);
    }

    /// @notice Set the buffer for a market
    /// @param marketId The ID of the market
    /// @param buffer The new buffer for the market
    function setBuffer(bytes32 marketId, uint256 buffer) external restricted {
        Market storage market = getLenderStorage().market[marketId];
        market.buffer = buffer;
        emit SetBuffer(marketId, buffer);
    }

    /// @notice Set the liquidation threshold for a market
    /// @param marketId The ID of the market
    /// @param lt The new liquidation threshold for the market
    function setLt(bytes32 marketId, uint256 lt) external restricted {
        Market storage market = getLenderStorage().market[marketId];
        market.lt = lt;
        emit SetLt(marketId, lt);
    }

    /// @notice Set the borrow cap for a market
    /// @param marketId The ID of the market
    /// @param borrowCap The maximum borrowing limit for the market
    function setBorrowCap(bytes32 marketId, uint256 borrowCap) external restricted {
        Market storage market = getLenderStorage().market[marketId];
        market.borrowCap = borrowCap;
        emit SetBorrowCap(marketId, borrowCap);
    }

    /// @notice Set the minimum and maximum supply rate multipliers for a market
    /// @param min The minimum multiplier
    /// @param max The maximum multiplier
    function setMultiplierLimits(uint256 min, uint256 max) external restricted {
        getLenderStorage().minMultiplier = min;
        getLenderStorage().maxMultiplier = max;
        emit SetMultiplierLimits(min, max);
    }

    /// @notice Get the maximum amount of cUSD that can be borrowed
    /// @param marketId The ID of the market
    /// @return borrowable The maximum amount of cUSD that can be borrowed
    function maxBorrowable(bytes32 marketId) public view returns (uint256 borrowable) {
        Market storage market = getLenderStorage().market[marketId];
        uint256 totalDebt = debt(marketId);
        uint256 remainingCredit = Math.min(market.borrowCap, availableCredit(marketId));
        borrowable = totalDebt > remainingCredit ? 0 : remainingCredit - totalDebt;
    }

    /// @notice Get the maximum amount of cUSD that can be liquidated
    /// @param marketId The ID of the market
    /// @return liquidatable The maximum amount of cUSD that can be liquidated
    function maxLiquidatable(bytes32 marketId) public view returns (uint256 liquidatable) {
        Storage storage $ = getLenderStorage();
        Market storage market = $.market[marketId];
        uint256 totalDebt = debt(marketId);
        uint256 credit = totalCredit(marketId);
        if (totalDebt > credit) {
            liquidatable = (($.targetHealth.rayMul(totalDebt) - credit).rayDiv($.targetHealth - market.lt));
            if (liquidatable > totalDebt) liquidatable = totalDebt;
        }
    }

    /// @notice Get the liquidation bonus percentage
    /// @dev Bonus increases along a kinked curve as market health declines, but is capped to prevent increased unhealthiness.
    /// @param marketId The ID of the market
    /// @return bonus The bonus percentage in ray decimals (1e27)
    function getBonus(bytes32 marketId) public view returns (uint256 bonus) {
        Storage storage $ = getLenderStorage();
        Market storage market = $.market[marketId];
        uint256 totalDebt = debt(marketId);
        if (totalDebt == 0) return 0;

        uint256 capital = totalCapital(marketId);
        if (totalDebt >= capital) return 0;

        uint256 health = capital.rayMul(market.lt).rayDiv(totalDebt);
        if (health >= 1e27) return 0;

        if (health > $.bonusKink) {
            bonus = $.bonusSlope0.rayMul(1e27 - health).rayDiv(1e27 - $.bonusKink);
        } else {
            bonus = $.bonusSlope0 + $.bonusSlope1.rayMul($.bonusKink - health).rayDiv($.bonusKink);
        }

        uint256 maxBonus = (capital - totalDebt).rayDiv(totalDebt);
        if (bonus > maxBonus) bonus = maxBonus;
    }

    /// @notice Get the borrow cap for a market
    /// @param marketId The ID of the market
    /// @return cap The borrowing limit for the market in USD (18 decimals)
    function borrowCap(bytes32 marketId) public view returns (uint256 cap) {
        cap = getLenderStorage().market[marketId].borrowCap;
    }

    /// @notice Get the available credit for a market
    /// @param marketId The ID of the market
    /// @return credit The available credit in USD (18 decimals)
    function availableCredit(bytes32 marketId) public view returns (uint256 credit) {
        Market storage market = getLenderStorage().market[marketId];
        uint256 availableAssets = IUnderwriter(market.seniorUnderwriter).activeAssets()
            + IUnderwriter(market.juniorUnderwriter).activeAssets();
        credit = availableAssets.rayDiv(getPrice(marketId)).rayMul(market.ltv);
    }

    /// @notice Get the total credit for a market
    /// @param marketId The ID of the market
    /// @return credit The total credit in USD (18 decimals)
    function totalCredit(bytes32 marketId) public view returns (uint256 credit) {
        Market storage market = getLenderStorage().market[marketId];
        credit = totalCapital(marketId).rayMul(market.lt);
    }

    /// @notice Get the total capital for a market
    /// @param marketId The ID of the market
    /// @return capital The total capital in USD (18 decimals)
    function totalCapital(bytes32 marketId) public view returns (uint256 capital) {
        Storage storage $ = getLenderStorage();
        Market storage market = $.market[marketId];
        capital = (IVault($.vault).balanceOf(market.seniorUnderwriter, market.asset)
                + IVault($.vault).balanceOf(market.juniorUnderwriter, market.asset))
        .rayDiv(getPrice(marketId));
    }

    /// @notice Get the utilization of a market
    /// @param marketId The ID of the market
    /// @return util The utilization of the market
    function utilization(bytes32 marketId) external view returns (uint256 util) {
        util = debt(marketId).rayDiv(totalCredit(marketId));
    }

    /// @notice Get the price of the asset for a market
    /// @param marketId The ID of the market
    /// @return price The price of the asset in USD (18 decimals)
    function getPrice(bytes32 marketId) public view returns (uint256 price) {
        Storage storage $ = getLenderStorage();
        (price,) = IOracle($.oracle).getPrice($.market[marketId].asset);
    }

    /// @notice Get the current debt owed by the borrower
    /// @dev marketDebt = scaledDebt * I_supply * I_underwriter
    /// @param marketId The ID of the market
    /// @return marketDebt The current debt in asset units
    function debt(bytes32 marketId) public view returns (uint256 marketDebt) {
        Market storage market = getLenderStorage().market[marketId];
        marketDebt = market.scaledDebt.rayMul(index(marketId));
    }

    /// @notice Get the scaled debt for a market
    /// @param marketId The ID of the market
    /// @return sDebt The scaled debt in asset units
    function scaledDebt(bytes32 marketId) external view returns (uint256 sDebt) {
        Market storage market = getLenderStorage().market[marketId];
        sDebt = market.scaledDebt;
    }

    /// @notice Get the supply interest index for a market
    /// @dev Reads the global supply IRM and scales it by the market multiplier:
    ///      I_supply = 1 + multiplier * (rawIndex - 1). Variable vs fixed is chosen per market.
    /// @param marketId The ID of the market
    /// @return currentIndex The current supply index in ray
    function supplyIndex(bytes32 marketId) public view returns (uint256 currentIndex) {
        Storage storage $ = getLenderStorage();
        Market storage market = $.market[marketId];
        currentIndex =
            market.variable ? IInterestRateModel($.irm).variableIndex() : IInterestRateModel($.irm).fixedIndex();
        uint256 mult = market.multiplier;
        currentIndex = 1e27 + currentIndex.rayMul(mult) - mult;
    }

    /// @notice Get the underwriter premium index for a market
    /// @dev Compounding index from the market's premium IRM (fixed at market creation). Premium accrues
    /// only when this index moves; a flat index accrues no new premium for the interval.
    /// @param marketId The ID of the market
    /// @return currentIndex The current underwriter premium index in ray
    function underwriterIndex(bytes32 marketId) public view returns (uint256 currentIndex) {
        Storage storage $ = getLenderStorage();
        currentIndex = IInverseInterestRateModel($.irm).index(marketId);
    }

    /// @notice Get the combined debt index for a market
    /// @dev I_combined = I_supply * I_underwriter. Debt is scaledDebt * I_combined. Interest is split in
    /// _update via the product rule: lastU * d(I_supply) to suppliers, I_supply * d(I_underwriter) to
    /// underwriters (charged on supply-owed debt, i.e. scaledDebt * I_supply).
    /// @param marketId The ID of the market
    /// @return currentIndex The current combined debt index in ray
    function index(bytes32 marketId) public view returns (uint256 currentIndex) {
        currentIndex = supplyIndex(marketId).rayMul(underwriterIndex(marketId));
    }

    /// @notice Get locked collateral for an underwriter tranche
    /// @dev Junior collateral covers debt first; senior only locks what junior cannot cover
    /// @param underwriter The underwriter tranche to query
    /// @return assets The amount of collateral locked
    function lockedAssets(bytes32 marketId, address underwriter) external view returns (uint256 assets) {
        Market storage market = getLenderStorage().market[marketId];
        assets = debt(marketId).rayDiv(market.lt - market.buffer).rayMul(getPrice(marketId));
        if (underwriter == market.seniorUnderwriter) {
            uint256 juniorAssets =
                IVault(address(getLenderStorage().vault)).balanceOf(market.juniorUnderwriter, market.asset);
            assets = assets > juniorAssets ? assets - juniorAssets : 0;
        }
    }

    /// @notice Validate the borrowing of a market
    /// @param marketId The ID of the market
    /// @param caller The caller of the borrow
    /// @param amount The amount to borrow
    function _validateBorrow(bytes32 marketId, address caller, uint256 amount) internal view {
        Market storage market = getLenderStorage().market[marketId];
        if (!market.borrowers.contains(caller)) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        uint256 maxBorrowable = maxBorrowable(marketId);
        if (amount > maxBorrowable) revert InsufficientLiquidity();
    }

    /// @notice Validate the liquidation of a market
    /// @param marketId The ID of the market
    function _validateLiquidate(bytes32 marketId) internal view {
        Market storage market = getLenderStorage().market[marketId];
        uint256 debt = debt(marketId);
        uint256 totalCredit = totalCredit(marketId);
        if (debt < totalCredit.rayMul(market.lt)) revert Solvent();
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
