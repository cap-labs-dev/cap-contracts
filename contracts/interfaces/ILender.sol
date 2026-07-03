// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ILender
/// @author kexley, Cap Labs
/// @notice Interface for Hub lending, liquidation, and market configuration
interface ILender {
    struct Storage {
        address stablecoin;
        address oracle;
        mapping(bytes32 => Market) market;
        EnumerableSet.Bytes32Set markets;
        mapping(address => bytes32) marketForTranche;
        address vault;
        address irm;
        address trancheBeacon;
        uint256 buffer;
        uint256 lt;
        uint256 minMultiplier;
        uint256 maxMultiplier;
        uint256 targetHealth;
        uint256 bonusKink;
        uint256 bonusSlope0;
        uint256 bonusSlope1;
        uint256 supplyReward;
        address stcUSD;
    }

    struct Market {
        address asset;
        uint8 decimals;
        uint256 buffer;
        uint256 lt;
        uint256 ltv;
        uint256 borrowCap;
        uint256 scaledDebt;
        address seniorTranche;
        address juniorTranche;
        bool variable;
        uint256 multiplier;
        EnumerableSet.AddressSet borrowers;
        uint256 lastSupplyIndex;
        uint256 lastTrancheIndex;
        uint256 lastIndexUpdate;
        uint256 juniorSplit;
        mapping(address => uint256) rewardPerShare;
        mapping(address => mapping(address => uint256)) pendingReward;
        mapping(address => mapping(address => uint256)) rewardDebt;
    }

    error Unauthorized();
    error InvalidAmount();
    error InsufficientLiquidity();
    error Solvent();
    error MarketAlreadyExists();
    error InvalidLtv();
    error InvalidMultiplier();
    error InvalidBorrower();
    error InvalidJuniorSplit();
    error InvalidTranche();

    event Borrow(bytes32 marketId, address caller, address recipient, uint256 amount);
    event Repay(bytes32 marketId, address caller, uint256 amount);
    event Liquidate(
        bytes32 marketId,
        address caller,
        address recipient,
        uint256 amount,
        address assetLiquidated,
        uint256 assetsSlashed
    );
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
    event CreateMarket(bytes32 marketId, address seniorTranche, address juniorTranche);
    event SetJuniorSplit(bytes32 marketId, uint256 juniorSplit);
    event SetStcUSD(address stcUSD);
    event ClaimSupplyReward(uint256 reward);
    event ClaimTrancheReward(address tranche, address recipient, uint256 reward);

    function borrow(bytes32 marketId, address recipient, uint256 amount) external returns (uint256 borrowed);
    function repay(bytes32 marketId, uint256 amount) external returns (uint256 repaid);
    function liquidate(bytes32 marketId, address recipient, uint256 amount)
        external
        returns (uint256 repaid, address assetLiquidated, uint256 assetsSlashed);
    function createMarket(
        string memory name,
        string memory symbol,
        address asset,
        uint256 ltv,
        address[] calldata borrowers
    ) external returns (bytes32 marketId, address seniorTranche, address juniorTranche);
    function setLtv(bytes32 marketId, uint256 ltv) external;
    function addBorrower(bytes32 marketId, address borrower) external;
    function removeBorrower(bytes32 marketId, address borrower) external;
    function setInterestType(bytes32 marketId, bool supplyVariable) external;
    function setMultiplier(bytes32 marketId, uint256 multiplier) external;
    function setDefaultBuffer(uint256 buffer) external;
    function setDefaultLt(uint256 lt) external;
    function setBuffer(bytes32 marketId, uint256 buffer) external;
    function setLt(bytes32 marketId, uint256 lt) external;
    function setBorrowCap(bytes32 marketId, uint256 borrowCap) external;
    function setMultiplierLimits(uint256 min, uint256 max) external;
    function setOracle(address oracle) external;
    function setTargetHealth(uint256 targetHealth) external;
    function setBonusConfig(uint256 kink, uint256 slope0, uint256 slope1) external;
    function setStcUSD(address stcUSD) external;
    function setJuniorSplit(bytes32 marketId, uint256 juniorSplit) external;
    function updateRewards(bytes32 marketId) external;
    function increaseRewardDebt(bytes32 marketId, address user, uint256 amount) external;
    function decreaseRewardDebt(bytes32 marketId, address user, uint256 amount) external;
    function claimSupplyReward() external returns (uint256 reward);
    function claimTrancheReward(address tranche, address recipient) external returns (uint256 reward);

    function claimableSupplyReward() external view returns (uint256 reward);
    function claimableTrancheReward(address tranche, address user) external view returns (uint256);
    function isTranche(address tranche) external view returns (bool);
    function utilization(bytes32 marketId) external view returns (uint256 utilization);
    function maxBorrowable(bytes32 marketId) external view returns (uint256 maxBorrowable);
    function maxLiquidatable(bytes32 marketId) external view returns (uint256 maxLiquidatable);
    function lockedAssets(bytes32 marketId, address underwriter) external view returns (uint256 lockedAssets);
    function supplyIndex(bytes32 marketId) external view returns (uint256 supplyIndex);
    function trancheIndex(bytes32 marketId) external view returns (uint256 trancheIndex);
    function scaledDebt(bytes32 marketId) external view returns (uint256 scaledDebt);
    function index(bytes32 marketId) external view returns (uint256 index);
}
