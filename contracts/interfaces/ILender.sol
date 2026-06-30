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
        address rewarder;
        address vault;
        address irm;
        address underwriterBeacon;
        uint256 buffer;
        uint256 lt;
        uint256 minMultiplier;
        uint256 maxMultiplier;
        uint256 targetHealth;
        uint256 bonusKink;
        uint256 bonusSlope0;
        uint256 bonusSlope1;
    }

    struct Market {
        address asset;
        uint8 decimals;
        address manager;
        uint256 buffer;
        uint256 lt;
        uint256 ltv;
        uint256 borrowCap;
        uint256 scaledDebt;
        address seniorUnderwriter;
        address juniorUnderwriter;
        bool variable;
        uint256 multiplier;
        EnumerableSet.AddressSet borrowers;
    }

    error Unauthorized();
    error InvalidAmount();
    error InsufficientLiquidity();
    error Solvent();
    error MarketAlreadyExists();
    error InvalidLtv();
    error InvalidManager();
    error InvalidMultiplier();
    error InvalidBorrower();

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
    event SetManager(bytes32 marketId, address manager);
    event SetInterestType(bytes32 marketId, bool supplyVariable);
    event SetMultiplier(bytes32 marketId, uint256 multiplier);
    event SetDefaultBuffer(uint256 buffer);
    event SetDefaultLt(uint256 lt);
    event SetBuffer(bytes32 marketId, uint256 buffer);
    event SetLt(bytes32 marketId, uint256 lt);
    event SetBorrowCap(bytes32 marketId, uint256 borrowCap);
    event SetMultiplierLimits(uint256 min, uint256 max);
    event SetOracle(address oracle);
    event CreateMarket(bytes32 marketId);

    function borrow(bytes32 marketId, address recipient, uint256 amount) external returns (uint256 borrowed);
    function repay(bytes32 marketId, uint256 amount) external returns (uint256 repaid);
    function liquidate(bytes32 marketId, address recipient, uint256 amount)
        external
        returns (uint256 repaid, address assetLiquidated, uint256 assetsSlashed);
    function setLtv(bytes32 marketId, uint256 ltv) external;
    function addBorrower(bytes32 marketId, address borrower) external;
    function removeBorrower(bytes32 marketId, address borrower) external;
    function setManager(bytes32 marketId, address manager) external;
    function setInterestType(bytes32 marketId, bool supplyVariable) external;
    function setMultiplier(bytes32 marketId, uint256 multiplier) external;
    function setDefaultBuffer(uint256 buffer) external;
    function setDefaultLt(uint256 lt) external;
    function setBuffer(bytes32 marketId, uint256 buffer) external;
    function setLt(bytes32 marketId, uint256 lt) external;
    function setBorrowCap(bytes32 marketId, uint256 borrowCap) external;
    function setMultiplierLimits(uint256 min, uint256 max) external;
    function utilization(bytes32 marketId) external view returns (uint256 utilization);
    function maxBorrowable(bytes32 marketId) external view returns (uint256 maxBorrowable);
    function maxLiquidatable(bytes32 marketId) external view returns (uint256 maxLiquidatable);
    function lockedAssets(bytes32 marketId, address underwriter) external view returns (uint256 lockedAssets);
    function supplyIndex(bytes32 marketId) external view returns (uint256 supplyIndex);
    function underwriterIndex(bytes32 marketId) external view returns (uint256 underwriterIndex);
    function scaledDebt(bytes32 marketId) external view returns (uint256 scaledDebt);
    function index(bytes32 marketId) external view returns (uint256 index);
}
