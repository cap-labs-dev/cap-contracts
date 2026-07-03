// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ILender } from "../interfaces/ILender.sol";
import { LendLib } from "../libraries/LendLib.sol";
import { RewardLib } from "../libraries/RewardLib.sol";
import { SetterLib } from "../libraries/SetterLib.sol";
import { ViewLib } from "../libraries/ViewLib.sol";
import { LenderStorageUtils } from "../storage/LenderStorageUtils.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Lender
/// @author kexley
/// @notice The Hub: the central contract for the Cap protocol. It manages markets, lending,
/// liquidation, and reward accrual. The bulk of the logic lives in dedicated libraries
/// (LendLib, SetterLib, ViewLib, RewardLib) that operate on its storage; this
/// contract is the thin, upgradeable entrypoint that wires them together and holds access control.
contract Lender is ILender, AccessManagedUpgradeable, LenderStorageUtils, UUPSUpgradeable {
    using ViewLib for ILender.Storage;

    /// @notice Initialize the Hub
    /// @param _authority The authority address
    /// @param _stablecoin The stablecoin address
    /// @param _trancheBeacon The tranche beacon address
    /// @param _oracle The oracle address
    /// @param _vault The vault address
    /// @param _irm The interest rate model address
    function initialize(
        address _authority,
        address _stablecoin,
        address _trancheBeacon,
        address _oracle,
        address _vault,
        address _irm
    ) external initializer {
        __AccessManaged_init(_authority);

        ILender.Storage storage $ = getLenderStorage();
        $.stablecoin = _stablecoin;
        $.trancheBeacon = _trancheBeacon;
        $.oracle = _oracle;
        $.vault = _vault;
        $.irm = _irm;
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Lending functions *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILender
    function borrow(bytes32 marketId, address recipient, uint256 amount) external returns (uint256 borrowed) {
        borrowed = LendLib.borrow(getLenderStorage(), marketId, recipient, amount);
    }

    /// @inheritdoc ILender
    function repay(bytes32 marketId, uint256 amount) external returns (uint256 repaid) {
        repaid = LendLib.repay(getLenderStorage(), marketId, amount);
    }

    /// @inheritdoc ILender
    function liquidate(bytes32 marketId, address recipient, uint256 amount)
        external
        returns (uint256 repaid, address assetLiquidated, uint256 assetsSlashed)
    {
        (repaid, assetLiquidated, assetsSlashed) = LendLib.liquidate(getLenderStorage(), marketId, recipient, amount);
    }

    /// @notice Create a new market
    function createMarket(
        string memory name,
        string memory symbol,
        address asset,
        uint256 ltv,
        address[] calldata borrowers
    ) external returns (bytes32 marketId, address seniorTranche, address juniorTranche) {
        (marketId, seniorTranche, juniorTranche) =
            LendLib.createMarket(getLenderStorage(), authority(), name, symbol, asset, ltv, borrowers);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Setter functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILender
    function setLtv(bytes32 marketId, uint256 ltv) external restricted {
        SetterLib.setLtv(getLenderStorage(), marketId, ltv);
    }

    /// @inheritdoc ILender
    function addBorrower(bytes32 marketId, address borrower) external restricted {
        SetterLib.addBorrower(getLenderStorage(), marketId, borrower);
    }

    /// @inheritdoc ILender
    function removeBorrower(bytes32 marketId, address borrower) external restricted {
        SetterLib.removeBorrower(getLenderStorage(), marketId, borrower);
    }

    /// @inheritdoc ILender
    function setInterestType(bytes32 marketId, bool supplyVariable) external restricted {
        SetterLib.setInterestType(getLenderStorage(), marketId, supplyVariable);
    }

    /// @inheritdoc ILender
    function setMultiplier(bytes32 marketId, uint256 multiplier) external restricted {
        SetterLib.setMultiplier(getLenderStorage(), marketId, multiplier);
    }

    /// @inheritdoc ILender
    function setDefaultBuffer(uint256 buffer) external restricted {
        SetterLib.setDefaultBuffer(getLenderStorage(), buffer);
    }

    /// @inheritdoc ILender
    function setDefaultLt(uint256 lt) external restricted {
        SetterLib.setDefaultLt(getLenderStorage(), lt);
    }

    /// @inheritdoc ILender
    function setBuffer(bytes32 marketId, uint256 buffer) external restricted {
        SetterLib.setBuffer(getLenderStorage(), marketId, buffer);
    }

    /// @inheritdoc ILender
    function setLt(bytes32 marketId, uint256 lt) external restricted {
        SetterLib.setLt(getLenderStorage(), marketId, lt);
    }

    /// @inheritdoc ILender
    function setBorrowCap(bytes32 marketId, uint256 cap) external restricted {
        SetterLib.setBorrowCap(getLenderStorage(), marketId, cap);
    }

    /// @inheritdoc ILender
    function setMultiplierLimits(uint256 min, uint256 max) external restricted {
        SetterLib.setMultiplierLimits(getLenderStorage(), min, max);
    }

    /// @inheritdoc ILender
    function setOracle(address oracle) external restricted {
        SetterLib.setOracle(getLenderStorage(), oracle);
    }

    /// @inheritdoc ILender
    function setTargetHealth(uint256 targetHealth) external restricted {
        SetterLib.setTargetHealth(getLenderStorage(), targetHealth);
    }

    /// @inheritdoc ILender
    function setBonusConfig(uint256 kink, uint256 slope0, uint256 slope1) external restricted {
        SetterLib.setBonusConfig(getLenderStorage(), kink, slope0, slope1);
    }

    /// @inheritdoc ILender
    function setStcUSD(address stcUSD) external restricted {
        SetterLib.setStcUSD(getLenderStorage(), stcUSD);
    }

    /// @inheritdoc ILender
    function setJuniorSplit(bytes32 marketId, uint256 juniorSplit) external {
        SetterLib.setJuniorSplit(getLenderStorage(), marketId, juniorSplit);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** Rewarding functions ***************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILender
    function updateRewards(bytes32 marketId) external {
        RewardLib.updateRewards(getLenderStorage(), marketId);
    }

    /// @notice Increase reward debt for a user
    function increaseRewardDebt(bytes32 marketId, address user, uint256 amount) external {
        RewardLib.increaseRewardDebt(getLenderStorage(), marketId, user, amount);
    }

    /// @inheritdoc ILender
    function decreaseRewardDebt(bytes32 marketId, address user, uint256 amount) external {
        RewardLib.decreaseRewardDebt(getLenderStorage(), marketId, user, amount);
    }

    /// @inheritdoc ILender
    function claimSupplyReward() external returns (uint256 reward) {
        reward = RewardLib.claimSupplyReward(getLenderStorage());
    }

    /// @inheritdoc ILender
    function claimTrancheReward(address tranche, address recipient) external returns (uint256 reward) {
        reward = RewardLib.claimTrancheReward(getLenderStorage(), tranche, recipient);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** View functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILender
    function utilization(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().utilization(marketId);
    }

    /// @inheritdoc ILender
    function maxBorrowable(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().maxBorrowable(marketId);
    }

    /// @inheritdoc ILender
    function maxLiquidatable(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().maxLiquidatable(marketId);
    }

    /// @inheritdoc ILender
    function lockedAssets(bytes32 marketId, address underwriter) external view returns (uint256) {
        return getLenderStorage().lockedAssets(marketId, underwriter);
    }

    /// @inheritdoc ILender
    function supplyIndex(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().supplyIndex(marketId);
    }

    /// @inheritdoc ILender
    function trancheIndex(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().trancheIndex(marketId);
    }

    /// @inheritdoc ILender
    function scaledDebt(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().scaledDebt(marketId);
    }

    /// @inheritdoc ILender
    function index(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().index(marketId);
    }

    /// @notice Get the price of the asset for a market
    function getPrice(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().getPrice(marketId);
    }

    /// @notice Get the current debt owed by the borrower
    function debt(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().debt(marketId);
    }

    /// @notice Get the total capital for a market
    function totalCapital(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().totalCapital(marketId);
    }

    /// @notice Get the total credit for a market
    function totalCredit(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().totalCredit(marketId);
    }

    /// @notice Get the available credit for a market
    function availableCredit(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().availableCredit(marketId);
    }

    /// @notice Get the liquidation bonus percentage
    function getBonus(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().getBonus(marketId);
    }

    /// @notice Get the borrow cap for a market
    function borrowCap(bytes32 marketId) external view returns (uint256) {
        return getLenderStorage().borrowCap(marketId);
    }

    /// @inheritdoc ILender
    function claimableSupplyReward() external view returns (uint256) {
        return getLenderStorage().claimableSupplyReward();
    }

    /// @inheritdoc ILender
    function claimableTrancheReward(address tranche, address user) external view returns (uint256) {
        return getLenderStorage().claimableTrancheReward(tranche, user);
    }

    /// @notice Check if an address is a tranche
    /// @param tranche The address to check
    /// @return isTranche Whether the address is a tranche
    function isTranche(address tranche) external view returns (bool) {
        return getLenderStorage().isTranche(tranche);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
