// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IMarket
/// @author kexley, Cap Labs
/// @notice Interface for per-market lending, liquidation, and configuration
interface IMarket {
    struct Storage {
        address asset;
        uint8 decimals;
        string name;
        address stablecoin;
        address stablecoinYield;
        address oracle;
        address vault;
        address irm;
        address seniorTranche;
        address juniorTranche;
        bool variable;
        uint256 multiplier;
        uint256 buffer;
        uint256 lt;
        uint256 ltv;
        uint256 borrowCap;
        uint256 scaledDebt;
        uint256 lastSupplyIndex;
        uint256 lastUnderwriterIndex;
        uint256 lastRewardUpdate;
        uint256 juniorSplit;
        uint256 targetHealth;
        uint256 bonusKink;
        uint256 bonusSlope0;
        uint256 bonusSlope1;
        mapping(address => uint256) reward;
    }

    error Unauthorized();
    error InvalidAmount();
    error InsufficientLiquidity();
    error Solvent();
    error InvalidLtv();
    error InvalidLt();
    error InvalidMultiplier();
    error InvalidJuniorSplit();
    error InvalidTranche();
    error InvalidAsset();
    error InvalidMarket();

    event Borrow(address caller, address recipient, uint256 amount);
    event Repay(address caller, uint256 amount);
    event Liquidate(address caller, address recipient, uint256 amount, uint256 assetsSlashed);
    event SetLtv(uint256 ltv);
    event SetInterestType(bool supplyVariable);
    event SetMultiplier(uint256 multiplier);
    event SetBuffer(uint256 buffer);
    event SetLt(uint256 lt);
    event SetBorrowCap(uint256 borrowCap);
    event SetOracle(address oracle);
    event SetTargetHealth(uint256 targetHealth);
    event SetBonusConfig(uint256 kink, uint256 slope0, uint256 slope1);
    event SetJuniorSplit(uint256 juniorSplit);
    event SetStablecoinYield(address stablecoinYield);
    event SetSeniorTranche(address seniorTranche);
    event SetJuniorTranche(address juniorTranche);
    event Claimed(address tranche, uint256 reward);

    function initialize(
        address authority,
        address asset,
        string memory name,
        uint256 multiplier,
        address irm,
        address stablecoin,
        address stablecoinYield,
        address vault,
        address oracle
    ) external;

    function borrow(address recipient, uint256 amount) external returns (uint256 borrowed);
    function repay(uint256 amount) external returns (uint256 repaid);
    function liquidate(address recipient, uint256 amount) external returns (uint256 repaid, uint256 assetsSlashed);
    function claim() external returns (uint256 reward);

    function setInterestType(bool supplyVariable) external;
    function setJuniorSplit(uint256 juniorSplit) external;
    function setMultiplier(uint256 multiplier) external;
    function setLtv(uint256 ltv) external;
    function setBuffer(uint256 buffer) external;
    function setLt(uint256 lt) external;
    function setBorrowCap(uint256 borrowCap) external;
    function setOracle(address oracle) external;
    function setTargetHealth(uint256 targetHealth) external;
    function setBonusConfig(uint256 kink, uint256 slope0, uint256 slope1) external;
    function setStablecoinYield(address stablecoinYield) external;
    function setSeniorTranche(address seniorTranche) external;
    function setJuniorTranche(address juniorTranche) external;

    function name() external view returns (string memory);
    function utilization() external view returns (uint256);
    function maxBorrowable() external view returns (uint256);
    function maxLiquidatable() external view returns (uint256);
    function lockedAssets(address tranche) external view returns (uint256);
    function debt() external view returns (uint256);
    function totalCapital() external view returns (uint256);
    function totalCredit() external view returns (uint256);
    function availableCredit() external view returns (uint256);
    function ltv() external view returns (uint256);
    function lt() external view returns (uint256);
    function buffer() external view returns (uint256);
    function bonus() external view returns (uint256);
    function borrowCap() external view returns (uint256);
    function juniorSplit() external view returns (uint256);
    function seniorTranche() external view returns (address);
    function juniorTranche() external view returns (address);
    function stablecoin() external view returns (address);
    function claimable(address tranche) external view returns (uint256);
}
