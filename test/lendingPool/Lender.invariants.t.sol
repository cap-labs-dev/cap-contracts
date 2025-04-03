// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";
import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { InitTestVaultLiquidity } from "../deploy/service/InitTestVaultLiquidity.sol";

import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";
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
    uint256 private constant EMERGENCY_LIQUIDATION_THRESHOLD = 0.91e27; // CR <110% have no grace periods

    function useMockBackingNetwork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);

        // Create and target handler
        handler = new TestLenderHandler(env);
        targetContract(address(handler));

        vm.label(address(handler), "TestLenderHandler");
    }

    function test_mock_network_borrow_and_repay_with_coverage() public {
        address user_agent = _getRandomAgent();
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 1000e6 + 10e6);
        lender.repay(address(usdc), 1000e6, user_agent);
        assertGe(usdc.balanceOf(address(cUSD)), backingBefore);

        (uint256 pdebt, uint256 idebt, uint256 rdebt) = lender.debt(user_agent, address(usdc));
        assertEq(pdebt, 0);
        assertEq(idebt, 0);
        assertEq(rdebt, 0);
    }

    function test_fuzzing_non_regression_liquidate_after_set_coverage() public {
        // [FAIL: panic: division or modulo by zero (0x12)]
        // [Sequence]
        //         sender=0x0000000000000000000000000000000000001207 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[5402, 4969, 4395]
        //         sender=0x0000000000000000000000000000000000000758 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[8504, 11352 [1.135e4]]
        //         sender=0x0000000000000000000000000000000000000423 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[1109431098096784405597004399778520969000778 [1.109e42], 937481123910104941 [9.374e17], 61623886549693656488416079379073384034876 [6.162e40], 3768160486856916064340765479018069586352278996523203668143 [3.768e57]]
        vm.startPrank(0x0000000000000000000000000000000000000EDf);
        handler.borrow(5402, 4969, 4395);
        vm.stopPrank();

        handler.setAgentCoverage(8504, 11352);

        vm.startPrank(0xbe7f92eB4a9550Fb1182d555cC6cD00fD7f573d7);
        handler.liquidate(
            1109431098096784405597004399778520969000778,
            937481123910104941,
            61623886549693656488416079379073384034876,
            3768160486856916064340765479018069586352278996523203668143
        );
        vm.stopPrank();

        invariant_borrowingLimits();
    }

    function test_fuzzing_non_regression_liquidate_fails() public {
        //         Encountered 1 failing test in test/lendingPool/Lender.invariants.t.sol:LenderInvariantsTest
        // [FAIL: invariant_borrowingLimits persisted failure revert]
        //         [Sequence]
        //                 sender=0x000000000000000000000000000000004DEeAad4 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[500000000000000000000000000 [5e26], 260243407 [2.602e8], 7520]
        //                 sender=0x0000000000000000000000000000000000002834 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[4763, 5672]
        //                 sender=0x0000000000000000000000000000000000000A2B addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[9998, 5300, 806165946075049551985264334151369441818954475481 [8.061e47], 5711]
        //                 sender=0x00000000000000000001ddDBFa0a9CD64ECaa149 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[11056068703988633693957203172599663392891881631940881250732208 [1.105e61], 30007872054813680496550892600715668912378495406850871 [3e52], 1928259676971630563350495955946765 [1.928e33], 420729907401969 [4.207e14]]
        //  invariant_borrowingLimits() (runs: 1, calls: 1, reverts: 1)

        vm.startPrank(0x000000000000000000000000000000004DEeAad4);
        handler.borrow(500000000000000000000000000, 260243407, 7520);
        vm.stopPrank();

        handler.setAgentCoverage(4763, 5672);

        vm.startPrank(0x0000000000000000000000000000000000000A2B);
        handler.liquidate(9998, 5300, 806165946075049551985264334151369441818954475481, 5711);
        vm.stopPrank();

        vm.startPrank(0x00000000000000000001ddDBFa0a9CD64ECaa149);
        handler.liquidate(
            11056068703988633693957203172599663392891881631940881250732208,
            30007872054813680496550892600715668912378495406850871,
            1928259676971630563350495955946765,
            420729907401969
        );
        vm.stopPrank();

        invariant_borrowingLimits();
    }

    /// @dev Test that total borrowed never exceeds available assets
    /// forge-config: default.invariant.depth = 25
    function invariant_borrowingLimits() public view {
        address[] memory assets = usdVault.assets;

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
    /// forge-config: default.invariant.depth = 25
    function invariant_agentDelegationLimitsDebt() public view {
        address[] memory agents = env.testUsers.agents;
        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            (uint256 totalDelegation, uint256 totalDebt,,,) = lender.agent(agent);
            uint256 maxLiquidatable = lender.maxLiquidatable(agent, address(usdc));
            console.log("totalDelegation", totalDelegation);
            console.log("totalDebt", totalDebt);
            console.log("maxLiquidatable", maxLiquidatable);
            if (maxLiquidatable == 0) {
                assertGe(totalDelegation, totalDebt, "User borrow must not exceed delegation");
            }
        }
    }
}

/**
 * @notice Handler contract for testing Lender invariants
 */
contract TestLenderHandler is StdUtils, TimeUtils, InitTestVaultLiquidity, RandomActorUtils, RandomAssetUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    TestEnvConfig env;

    Lender lender;

    constructor(TestEnvConfig memory _env)
        RandomActorUtils(_env.testUsers.agents)
        RandomAssetUtils(_env.usdVault.assets)
    {
        env = _env;
        lender = Lender(env.infra.lender);
    }

    function _randomUnpausedAsset(uint256 assetSeed) internal view returns (address) {
        address[] memory assets = allAssets();
        address[] memory unpausedAssets = new address[](assets.length);
        uint256 unpausedAssetCount = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            (,,,,,,, bool paused,) = lender.reservesData(assets[i]);
            if (!paused) {
                unpausedAssets[unpausedAssetCount++] = assets[i];
            }
        }

        if (unpausedAssetCount == 0) return address(0);

        return unpausedAssets[bound(assetSeed, 0, unpausedAssetCount - 1)];
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address agent = randomActor(actorSeed);
        address currentAsset = _randomUnpausedAsset(assetSeed);
        if (currentAsset == address(0)) return;

        uint256 availableToBorrow = lender.maxBorrowable(agent, currentAsset);
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

        // Execute repay
        {
            vm.startPrank(agent);
            IERC20(currentAsset).approve(address(lender), amount);

            lender.repay(currentAsset, amount, agent);
            vm.stopPrank();
        }
    }

    function liquidate(uint256 agentSeed, uint256 liquidatorSeed, uint256 assetSeed, uint256 amount) external {
        address agent = randomActor(agentSeed);
        address liquidator = randomActorExcept(liquidatorSeed, agent);
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to liquidatable amount
        amount = bound(amount, 0, lender.maxLiquidatable(agent, currentAsset));
        if (amount == 0) return;

        // Execute liquidation
        {
            vm.startPrank(liquidator);

            // Mint tokens to repay for the user liquidation
            MockERC20(currentAsset).mint(liquidator, amount);

            // Execute liquidation
            IERC20(currentAsset).approve(address(lender), amount);

            if (lender.liquidationStart(agent) == 0) {
                lender.initiateLiquidation(agent);
                _timeTravel(lender.grace() + 1);
            }

            lender.liquidate(agent, currentAsset, amount);
            vm.stopPrank();
        }
    }

    function setAgentCoverage(uint256 agentSeed, uint256 coverage) external {
        coverage = bound(coverage, 0, 1e50);
        address agent = randomActor(agentSeed);

        vm.prank(address(env.users.middleware_admin));
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockCoverage(agent, coverage);
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockSlashableCollateral(
            agent, coverage
        );
        vm.stopPrank();
    }

    function realizeInterest(uint256 assetSeed, uint256 amount) external {
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to a reasonable range (using type(uint96).max to avoid overflow)
        uint256 maxRealization = lender.maxRealization(currentAsset);
        if (maxRealization == 0) return;

        amount = bound(amount, 0, maxRealization);

        // deal some cUSD to the realizer
        address realizer = randomActor(assetSeed);
        _initTestUserMintCapToken(env.usdVault, realizer, amount);

        lender.realizeInterest(currentAsset, amount);
    }

    function cancelLiquidation(uint256 agentSeed) external {
        address agent = randomActor(agentSeed);

        // Only attempt to cancel if there's an active liquidation
        if (lender.liquidationStart(agent) > 0) {
            (,,,, uint256 health) = lender.agent(agent);
            // Only cancel if health is above 1e27 (healthy)
            if (health >= 1e27) {
                vm.prank(address(env.users.lender_admin));
                lender.cancelLiquidation(agent);
                vm.stopPrank();
            }
        }
    }

    function pauseAsset(uint256 assetSeed, uint256 pauseFlag) external {
        address currentAsset = randomAsset(assetSeed);
        bool shouldPause = pauseFlag % 2 == 1; // Convert to boolean randomly

        // Only admin can pause/unpause
        vm.prank(address(env.users.lender_admin));
        lender.pauseAsset(currentAsset, shouldPause);
        vm.stopPrank();
    }
}
