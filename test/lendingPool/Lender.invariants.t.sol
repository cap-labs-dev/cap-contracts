// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DataTypes } from "../../contracts/lendingPool/libraries/types/DataTypes.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";
import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { RandomActorUtils } from "../deploy/utils/RandomActorUtils.sol";
import { RandomAssetUtils } from "../deploy/utils/RandomAssetUtils.sol";
import { TimeUtils } from "../deploy/utils/TimeUtils.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";

import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract LenderInvariantsTest is TestDeployer {
    TestLenderHandler public handler;
    address[] private actors;

    // Constants - all values in ray (1e27)
    uint256 private constant TARGET_HEALTH = 2e27; // 2.0 target health factor
    uint256 private constant BONUS_CAP = 1.1e27; // 110% bonus cap
    uint256 private constant GRACE_PERIOD = 1 days;
    uint256 private constant EXPIRY_PERIOD = 7 days;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        _initSymbioticVaultsLiquidity(env);

        // Create and target handler
        handler = new TestLenderHandler(env);
        targetContract(address(handler));
    }

    /// @dev Test that total borrowed never exceeds available assets
    /// forge-config: default.invariant.runs = 5
    /// forge-config: default.invariant.depth = 20
    function invariant_borrowingLimits() public view {
        address[] memory assets = env.vault.assets;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 totalBorrowed = 0;

            // Sum up all actor debts
            for (uint256 j = 0; j < actors.length; j++) {
                (, uint256 totalDebt,,,) = lender.agent(actors[j]);
                totalBorrowed += totalDebt;
            }

            uint256 availableAssets = IERC20(asset).balanceOf(address(lender));
            assertLe(totalBorrowed, availableAssets, "Total borrowed must not exceed available assets");
        }
    }

    /// @dev Test that user borrows never exceed their delegation
    /// forge-config: default.invariant.runs = 5
    /// forge-config: default.invariant.depth = 20
    function invariant_agentDelegationLimitsDebt() public view {
        address[] memory agents = env.testUsers.agents;
        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            (uint256 totalDelegation, uint256 totalDebt,,,) = lender.agent(agent);
            console.log("totalDelegation", totalDelegation);
            console.log("totalDebt", totalDebt);
            assertGe(totalDelegation, totalDebt, "User borrow must not exceed delegation");
        }
    }
}

/**
 * @notice Handler contract for testing Lender invariants
 */
contract TestLenderHandler is StdUtils, TimeUtils, RandomActorUtils, RandomAssetUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    TestEnvConfig env;

    Lender lender;

    constructor(TestEnvConfig memory _env)
        RandomActorUtils(_env.testUsers.agents)
        RandomAssetUtils(_env.vault.assets)
    {
        env = _env;
        lender = Lender(env.infra.lender);
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address agent = randomActor(actorSeed);
        address currentAsset = randomAsset(assetSeed);

        uint256 availableToBorrow = lender.maxBorrowable(agent, currentAsset);
        console.log("availableToBorrow", availableToBorrow);
        amount = bound(amount, 0, availableToBorrow);
        if (amount == 0) return;

        vm.startPrank(agent);
        lender.borrow(currentAsset, amount, agent);
        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address agent = randomActor(actorSeed);
        address currentAsset = randomAsset(assetSeed);

        (, uint256 totalDebt,,,) = lender.agent(agent);

        // Bound amount to actual borrowed amount
        amount = bound(amount, 0, totalDebt);
        if (amount == 0) return;

        // Mint tokens to repay
        MockERC20(currentAsset).mint(agent, amount);
        IERC20(currentAsset).approve(address(lender), amount);

        // Execute repay
        vm.startPrank(agent);
        lender.repay(currentAsset, amount, agent);
        vm.stopPrank();
    }

    function liquidate(uint256 agentSeed, uint256 liquidatorSeed, uint256 assetSeed, uint256 amount) external {
        address agent = randomActor(agentSeed);
        address liquidator = randomActorExcept(liquidatorSeed, agent);
        address currentAsset = randomAsset(assetSeed);

        (,,,, uint256 health) = lender.agent(agent);
        if (health >= 1e27) return;

        // Get current debt
        (, uint256 totalDebt,,,) = lender.agent(agent);

        // Bound amount to liquidatable amount
        amount = bound(amount, 0, Math.min(totalDebt, type(uint96).max));
        if (amount == 0) return;

        // Mint tokens for liquidation
        MockERC20(currentAsset).mint(agent, amount);
        IERC20(currentAsset).approve(address(lender), amount);

        // Execute liquidation
        vm.startPrank(liquidator);
        lender.initiateLiquidation(agent);
        _timeTravel(lender.grace() + 1);
        lender.liquidate(agent, currentAsset, amount);
        vm.stopPrank();
    }
}
