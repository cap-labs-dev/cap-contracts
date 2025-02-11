// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DataTypes } from "../../contracts/lendingPool/libraries/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";

import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract LenderInvariantsTest is Test, ProxyUtils {
    TestLenderHandler public handler;
    Lender public lender;
    address[] public assets;
    address public constant MOCK_ACCESS_CONTROL = address(1);
    address public constant MOCK_DELEGATION = address(2);
    MockOracle public oracle;

    // Mock tokens
    MockERC20[] private mockTokens;
    address[] private actors;

    // Constants
    uint256 private constant LTV = 0.75e18; // 75% LTV
    uint256 private constant BASE_INTEREST_RATE = 0.05e18; // 5% base rate
    uint256 private constant OPTIMAL_UTILIZATION = 0.8e18; // 80% optimal utilization
    uint256 private constant TARGET_HEALTH = 2e18; // 2.0 target health factor
    uint256 private constant BONUS_CAP = 1.1e18; // 110% bonus cap
    uint256 private constant GRACE_PERIOD = 1 days;
    uint256 private constant EXPIRY_PERIOD = 7 days;

    function setUp() public {
        // Setup mock assets
        mockTokens = new MockERC20[](3);
        assets = new address[](3);

        // Create mock tokens with different decimals
        mockTokens[0] = new MockERC20("Mock Token 1", "MT1", 18);
        mockTokens[1] = new MockERC20("Mock Token 2", "MT2", 6);
        mockTokens[2] = new MockERC20("Mock Token 3", "MT3", 8);

        for (uint256 i = 0; i < 3; i++) {
            assets[i] = address(mockTokens[i]);
        }

        // Deploy oracle and set initial prices
        oracle = new MockOracle();
        for (uint256 i = 0; i < assets.length; i++) {
            oracle.setPrice(assets[i], 1e18); // Initial price of 1 USD
        }

        // Deploy implementation and proxy
        Lender implementation = new Lender();
        address proxy = _proxy(address(implementation));
        lender = Lender(proxy);

        // Initialize the proxied contract
        lender.initialize(
            MOCK_ACCESS_CONTROL, MOCK_DELEGATION, address(oracle), TARGET_HEALTH, GRACE_PERIOD, EXPIRY_PERIOD, BONUS_CAP
        );

        // Setup initial actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("Actor", vm.toString(i))));
            actors.push(actor);
        }

        // Create and target handler
        handler = new TestLenderHandler(
            lender,
            assets,
            actors,
            oracle,
            LTV,
            BASE_INTEREST_RATE,
            OPTIMAL_UTILIZATION,
            TARGET_HEALTH,
            BONUS_CAP,
            GRACE_PERIOD,
            EXPIRY_PERIOD
        );
        targetContract(address(handler));

        // Label contracts for better traces
        vm.label(address(lender), "LENDER");
        vm.label(address(handler), "HANDLER");
        vm.label(address(oracle), "ORACLE");
    }

    /// @dev Test that total borrowed never exceeds available assets
    function invariant_borrowingLimits() public view {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 totalBorrowed = handler.totalBorrows(asset, address(0));
            uint256 availableAssets = IERC20(asset).balanceOf(address(lender));
            assertLe(totalBorrowed, availableAssets, "Total borrowed must not exceed available assets");
        }
    }

    /// @dev Test that user borrows never exceed their collateral value * LTV
    function invariant_userBorrowLimits() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 borrowValue = handler.getUserBorrowValue(actor);
            uint256 collateralValue = handler.getUserCollateralValue(actor);
            uint256 maxBorrow = (collateralValue * LTV) / 1e18;

            assertLe(borrowValue, maxBorrow, "User borrow must not exceed collateral * LTV");
        }
    }

    /// @dev Test that health factors are maintained
    function invariant_healthFactors() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            if (handler.getUserBorrowValue(actor) > 0) {
                uint256 healthFactor = handler.getHealthFactor(actor);
                if (!handler.isInGracePeriod(actor)) {
                    assertGe(healthFactor, 1e18, "Health factor must be >= 1 outside grace period");
                }
            }
        }
    }

    /// @dev Test that liquidation mechanics work correctly
    function invariant_liquidationMechanics() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            if (handler.canBeLiquidated(actor)) {
                uint256 healthFactor = handler.getHealthFactor(actor);
                assertLt(healthFactor, 1e18, "Liquidatable positions must have health factor < 1");
                assertTrue(!handler.isInGracePeriod(actor), "Cannot liquidate during grace period");
                assertTrue(!handler.isExpired(actor), "Cannot liquidate expired positions");
            }
        }
    }
}

/**
 * @notice Handler contract for testing Lender invariants
 */
contract TestLenderHandler is StdUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Lender public lender;
    address[] public assets;
    address[] public actors;
    MockOracle public oracle;

    // Constants
    uint256 public immutable LTV;
    uint256 public immutable BASE_INTEREST_RATE;
    uint256 public immutable OPTIMAL_UTILIZATION;
    uint256 public immutable TARGET_HEALTH;
    uint256 public immutable BONUS_CAP;
    uint256 public immutable GRACE_PERIOD;
    uint256 public immutable EXPIRY_PERIOD;

    // Ghost variables for tracking state
    mapping(address => mapping(address => uint256)) public totalBorrows; // asset => user => amount
    mapping(address => uint256) public lastBorrowTimes; // user => timestamp
    mapping(address => mapping(address => uint256)) public collateral; // user => asset => amount

    // Actor management
    address internal currentActor;
    address internal currentAsset;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useAsset(uint256 assetSeed) {
        currentAsset = assets[bound(assetSeed, 0, assets.length - 1)];
        _;
    }

    constructor(
        Lender _lender,
        address[] memory _assets,
        address[] memory _actors,
        MockOracle _oracle,
        uint256 _ltv,
        uint256 _baseRate,
        uint256 _optimalUtilization,
        uint256 _targetHealth,
        uint256 _bonusCap,
        uint256 _gracePeriod,
        uint256 _expiryPeriod
    ) {
        lender = _lender;
        assets = _assets;
        actors = _actors;
        oracle = _oracle;
        LTV = _ltv;
        BASE_INTEREST_RATE = _baseRate;
        OPTIMAL_UTILIZATION = _optimalUtilization;
        TARGET_HEALTH = _targetHealth;
        BONUS_CAP = _bonusCap;
        GRACE_PERIOD = _gracePeriod;
        EXPIRY_PERIOD = _expiryPeriod;
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount)
        external
        useActor(actorSeed)
        useAsset(assetSeed)
    {
        // Calculate max borrow based on collateral
        uint256 collateralValue = getUserCollateralValue(currentActor);
        uint256 maxBorrow = (collateralValue * LTV) / 1e18;
        uint256 currentBorrows = getUserBorrowValue(currentActor);
        uint256 availableToBorrow = maxBorrow > currentBorrows ? maxBorrow - currentBorrows : 0;

        // Bound the amount
        amount = bound(amount, 0, Math.min(availableToBorrow, type(uint96).max));
        if (amount == 0) return;

        // Execute borrow
        lender.borrow(currentAsset, amount, currentActor);

        // Update ghost variables
        totalBorrows[currentAsset][currentActor] += amount;
        lastBorrowTimes[currentActor] = block.timestamp;
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount)
        external
        useActor(actorSeed)
        useAsset(assetSeed)
    {
        // Bound amount to actual borrowed amount
        amount = bound(amount, 0, totalBorrows[currentAsset][currentActor]);
        if (amount == 0) return;

        // Mint tokens to repay
        MockERC20(currentAsset).mint(currentActor, amount);
        IERC20(currentAsset).approve(address(lender), amount);

        // Execute repay
        lender.repay(currentAsset, amount, currentActor);

        // Update ghost variables
        totalBorrows[currentAsset][currentActor] -= amount;
    }

    function liquidate(uint256 liquidatorSeed, uint256 borrowerSeed, uint256 assetSeed, uint256 amount)
        external
        useActor(liquidatorSeed)
        useAsset(assetSeed)
    {
        address borrower = actors[bound(borrowerSeed, 0, actors.length - 1)];
        if (currentActor == borrower) return;
        if (!canBeLiquidated(borrower)) return;

        // Bound amount to liquidatable amount
        uint256 borrowed = totalBorrows[currentAsset][borrower];
        amount = bound(amount, 0, Math.min(borrowed, type(uint96).max));
        if (amount == 0) return;

        // Mint tokens for liquidation
        MockERC20(currentAsset).mint(currentActor, amount);
        IERC20(currentAsset).approve(address(lender), amount);

        // Execute liquidation
        lender.liquidate(borrower, currentAsset, amount);

        // Update ghost variables
        totalBorrows[currentAsset][borrower] -= amount;
    }

    // View functions for invariant testing
    function getUserBorrowValue(address user) public view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 borrowed = totalBorrows[asset][user];
            (uint256 price,) = oracle.getPrice(asset);
            totalValue += (borrowed * price) / 1e18;
        }
        return totalValue;
    }

    function getUserCollateralValue(address user) public view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amount = collateral[user][asset];
            (uint256 price,) = oracle.getPrice(asset);
            totalValue += (amount * price) / 1e18;
        }
        return totalValue;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 borrowValue = getUserBorrowValue(user);
        if (borrowValue == 0) return type(uint256).max;

        uint256 collateralValue = getUserCollateralValue(user);
        return (collateralValue * 1e18) / borrowValue;
    }

    function isInGracePeriod(address user) public view returns (bool) {
        return block.timestamp < lastBorrowTimes[user] + GRACE_PERIOD;
    }

    function isExpired(address user) public view returns (bool) {
        return block.timestamp > lastBorrowTimes[user] + GRACE_PERIOD + EXPIRY_PERIOD;
    }

    function canBeLiquidated(address user) public view returns (bool) {
        if (getHealthFactor(user) >= 1e18) return false;
        if (isInGracePeriod(user)) return false;
        if (isExpired(user)) return false;
        return true;
    }

    function getMaxWithdrawal(address user, address asset) public view returns (uint256) {
        uint256 userCollateral = collateral[user][asset];
        if (userCollateral == 0) return 0;

        uint256 borrowValue = getUserBorrowValue(user);
        if (borrowValue == 0) return userCollateral;

        (uint256 assetPrice,) = oracle.getPrice(asset);
        uint256 maxWithdrawValue = getUserCollateralValue(user) - (borrowValue * 1e18) / LTV;
        return (maxWithdrawValue * 1e18) / assetPrice;
    }
}
