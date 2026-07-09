// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IMarket } from "../interfaces/IMarket.sol";
import { LendLib } from "../libraries/LendLib.sol";
import { RewardLib } from "../libraries/RewardLib.sol";
import { SetterLib } from "../libraries/SetterLib.sol";
import { ViewLib } from "../libraries/ViewLib.sol";
import { MarketStorageUtils } from "../storage/MarketStorageUtils.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Market
/// @author kexley, Cap Labs
/// @notice Borrow market
contract Market is IMarket, AccessManagedUpgradeable, MarketStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IMarket
    function initialize(
        address _authority,
        address _asset,
        string memory _name,
        uint256 _multiplier,
        address _irm,
        address _stablecoin,
        address _stablecoinYield,
        address _vault,
        address _oracle
    ) external initializer {
        __AccessManaged_init(_authority);
        Storage storage $ = getMarketStorage();

        $.asset = _asset;
        $.decimals = IERC20Metadata(_asset).decimals();
        $.name = _name;
        $.multiplier = _multiplier;
        $.irm = _irm;
        $.stablecoin = _stablecoin;
        $.stablecoinYield = _stablecoinYield;
        $.vault = _vault;
        $.oracle = _oracle;

        $.lt = 0.8e27;
        $.buffer = 0.05e27;
        $.targetHealth = 1.25e27;
        $.variable = true;
        $.lastSupplyIndex = 1e27;
        $.lastUnderwriterIndex = 1e27;
    }

    /// @inheritdoc IMarket
    function borrow(address recipient, uint256 amount) external restricted returns (uint256 borrowed) {
        borrowed = LendLib.borrow(getMarketStorage(), recipient, amount);
    }

    /// @inheritdoc IMarket
    function repay(uint256 amount) external returns (uint256 repaid) {
        repaid = LendLib.repay(getMarketStorage(), amount);
    }

    /// @inheritdoc IMarket
    function liquidate(address recipient, uint256 amount) external returns (uint256 repaid, uint256 assetsSlashed) {
        (repaid, assetsSlashed) = LendLib.liquidate(getMarketStorage(), recipient, amount);
    }

    /// @inheritdoc IMarket
    function claim() external returns (uint256 reward) {
        reward = RewardLib.claim(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function setInterestType(bool _interestType) external restricted {
        SetterLib.setInterestType(getMarketStorage(), _interestType);
    }

    /// @inheritdoc IMarket
    function setJuniorSplit(uint256 _juniorSplit) external restricted {
        SetterLib.setJuniorSplit(getMarketStorage(), _juniorSplit);
    }

    /// @inheritdoc IMarket
    function setMultiplier(uint256 _multiplier) external restricted {
        SetterLib.setMultiplier(getMarketStorage(), _multiplier);
    }

    /// @inheritdoc IMarket
    function setLtv(uint256 _ltv) external restricted {
        SetterLib.setLtv(getMarketStorage(), _ltv);
    }

    /// @inheritdoc IMarket
    function setBuffer(uint256 _buffer) external restricted {
        SetterLib.setBuffer(getMarketStorage(), _buffer);
    }

    /// @inheritdoc IMarket
    function setLt(uint256 _lt) external restricted {
        SetterLib.setLt(getMarketStorage(), _lt);
    }

    /// @inheritdoc IMarket
    function setBorrowCap(uint256 _borrowCap) external restricted {
        SetterLib.setBorrowCap(getMarketStorage(), _borrowCap);
    }

    /// @inheritdoc IMarket
    function setOracle(address _oracle) external restricted {
        SetterLib.setOracle(getMarketStorage(), _oracle);
    }

    /// @inheritdoc IMarket
    function setTargetHealth(uint256 _targetHealth) external restricted {
        SetterLib.setTargetHealth(getMarketStorage(), _targetHealth);
    }

    /// @inheritdoc IMarket
    function setBonusConfig(uint256 _kink, uint256 _slope0, uint256 _slope1) external restricted {
        SetterLib.setBonusConfig(getMarketStorage(), _kink, _slope0, _slope1);
    }

    /// @inheritdoc IMarket
    function setStablecoinYield(address _stablecoinYield) external restricted {
        SetterLib.setStablecoinYield(getMarketStorage(), _stablecoinYield);
    }

    /// @inheritdoc IMarket
    function setSeniorTranche(address _seniorTranche) external restricted {
        SetterLib.setSeniorTranche(getMarketStorage(), _seniorTranche);
    }

    /// @inheritdoc IMarket
    function setJuniorTranche(address _juniorTranche) external restricted {
        SetterLib.setJuniorTranche(getMarketStorage(), _juniorTranche);
    }

    /// @inheritdoc IMarket
    function name() external view returns (string memory) {
        return ViewLib.name(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function utilization() external view returns (uint256) {
        return ViewLib.utilization(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function maxBorrowable() external view returns (uint256) {
        return ViewLib.maxBorrowable(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function maxLiquidatable() external view returns (uint256) {
        return ViewLib.maxLiquidatable(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function lockedAssets(address tranche) external view returns (uint256) {
        return ViewLib.lockedAssets(getMarketStorage(), tranche);
    }

    /// @inheritdoc IMarket
    function debt() external view returns (uint256) {
        return ViewLib.debt(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function totalCapital() external view returns (uint256) {
        return ViewLib.totalCapital(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function totalCredit() external view returns (uint256) {
        return ViewLib.totalCredit(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function availableCredit() external view returns (uint256) {
        return ViewLib.availableCredit(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function ltv() external view returns (uint256) {
        return ViewLib.ltv(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function lt() external view returns (uint256) {
        return ViewLib.lt(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function buffer() external view returns (uint256) {
        return ViewLib.buffer(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function bonus() external view returns (uint256) {
        return ViewLib.bonus(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function borrowCap() external view returns (uint256) {
        return ViewLib.borrowCap(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function juniorSplit() external view returns (uint256) {
        return ViewLib.juniorSplit(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function seniorTranche() external view returns (address) {
        return ViewLib.seniorTranche(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function juniorTranche() external view returns (address) {
        return ViewLib.juniorTranche(getMarketStorage());
    }

    /// @inheritdoc IMarket
    function claimable(address tranche) external view returns (uint256) {
        return ViewLib.claimable(getMarketStorage(), tranche);
    }

    /// @inheritdoc IMarket
    function stablecoin() external view returns (address) {
        return getMarketStorage().stablecoin;
    }
}
