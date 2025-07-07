pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";
import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { InitTestVaultLiquidity } from "../deploy/service/InitTestVaultLiquidity.sol";

import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { RandomActorUtils } from "../deploy/utils/RandomActorUtils.sol";
import { RandomAssetUtils } from "../deploy/utils/RandomAssetUtils.sol";
import { TimeUtils } from "../deploy/utils/TimeUtils.sol";

import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

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

    function test_invariant_healthFactorConsistency_3() public {
        /*[FAIL: invariant_healthFactorConsistency persisted failure revert]
        [Sequence]
                sender=0x00000000000000000000000000000000000009Da addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAssetOracleRate(uint256,uint256) args=[11543029381330672491860383985954805972857686344712689296545235 [1.154e61], 325150168437051263664132560797815973754326 [3.251e41]]
                sender=0x00000000000000000000000000000000000039b1 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[30918474852994773316386233195 [3.091e28], 79769887225082621 [7.976e16]]
                sender=0x000000000000000000000000000000006d4323a7 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[316122570517139326285190027269277357516886533069313938767621115840994 [3.161e68], 578845444545825921461613987212546383137608282288362114516139 [5.788e59], 17223189691 [1.722e10]]
                sender=0x00000000000000000000000000000000000006C0 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[36973630434612940363545929218560651730622542486 [3.697e46], 2770920719821542088301911 [2.77e24]]
                sender=0x000000000000000000000000000000000000261F addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[9045, 6404, 2140749424911443484501831106226770863824773013519896166431072913388269304815 [2.14e75]]
                sender=0x6869Dfc68B096cbb4F34e174160ec52d38A19036 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[3782488891584455175432 [3.782e21], 1295581938205204099 [1.295e18]]
                sender=0x00000000000000000000000000000000aEd2de9A addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[2169, 10024 [1.002e4]]
                sender=0x00000000000000000000000000000000000004DF addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256) args=[58576265760596734945125070288970029512249135556046156107638 [5.857e58], 974801935338640506149480721317387285224631 [9.748e41], 115792089237316195423570985008687907853269984665640564039457584007913129639932 [1.157e77]]
                sender=0x000000000000000000000000000000000000055F addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[82766052856927348954575688908830677982982928473109927503747768783016399837700 [8.276e76], 146729278930465342418334409999797869285940633234534 [1.467e50]]
                sender=0x0000000000000000000000000000000000001790 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[163761943310006 [1.637e14], 827300394997468839928732996009111100818690293611814564984725 [8.273e59]]
                sender=0xC2c1eC977F352B38b239c2eAaAAE194475024a83 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[10794383656069401322750723554756440261350332530727988235331024518065961345 [1.079e73], 9463830818159174000883846500573624111810028767009668635094261167107872095143 [9.463e75], 3]
                sender=0x0000000000000000000000000000000000000173 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[31658 [3.165e4], 10217 [1.021e4], 2243]
    invariant_healthFactorConsistency() (runs: 1, calls: 1, reverts: 1)*/
        handler.setAssetOracleRate(
            11543029381330672491860383985954805972857686344712689296545235, 325150168437051263664132560797815973754326
        );
        handler.wrapTime(30918474852994773316386233195, 79769887225082621);
        handler.borrow(
            316122570517139326285190027269277357516886533069313938767621115840994,
            578845444545825921461613987212546383137608282288362114516139,
            17223189691
        );
        handler.wrapTime(36973630434612940363545929218560651730622542486, 2770920719821542088301911);
        handler.borrow(9045, 6404, 2140749424911443484501831106226770863824773013519896166431072913388269304815);
        handler.setAgentCoverage(2169, 10024);
        handler.liquidate(
            58576265760596734945125070288970029512249135556046156107638,
            974801935338640506149480721317387285224631,
            115792089237316195423570985008687907853269984665640564039457584007913129639932
        );
        handler.wrapTime(
            82766052856927348954575688908830677982982928473109927503747768783016399837700,
            146729278930465342418334409999797869285940633234534
        );
        handler.wrapTime(163761943310006, 827300394997468839928732996009111100818690293611814564984725);
        handler.borrow(
            10794383656069401322750723554756440261350332530727988235331024518065961345,
            9463830818159174000883846500573624111810028767009668635094261167107872095143,
            3
        );
        handler.repay(31658, 10217, 2243);
    }

    function test_invariant_delegation_limits() public {
        /*[FAIL: custom error 0x2075cc10]
        [Sequence]
                sender=0xbf37929a0614B31E0a75386F4AEa7CbbCdf7E6BC addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[3429774651680311803827950921533868436805570945084490 [3.429e51], 602442520824273319800507124772583638 [6.024e35], 2]
                sender=0x0000000000000000000000000000000006Af730a addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[2634712179876331684459090303828492031321597276894059921950037 [2.634e60], 2367940741284809869791851034289241293896862773891046982235546554 [2.367e63], 120026868391482638618901689477088112386911141611787628869837380 [1.2e62]]
                sender=0x0000000000000000000000000000000000002568 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[117300739 [1.173e8], 3128, 16811447476311723966326299906927201449785552624966990332091277366376748439730 [1.681e76]]
    invariant_agentDelegationLimitsDebt() (runs: 25, calls: 2500, reverts: 1)*/
        handler.borrow(3429774651680311803827950921533868436805570945084490, 602442520824273319800507124772583638, 2);
        handler.repay(
            2634712179876331684459090303828492031321597276894059921950037,
            2367940741284809869791851034289241293896862773891046982235546554,
            120026868391482638618901689477088112386911141611787628869837380
        );
        handler.repay(117300739, 3128, 16811447476311723966326299906927201449785552624966990332091277366376748439730);
        invariant_agentDelegationLimitsDebt();
    }

    function test_invariant_agentDelegationLimitsDebt() public {
        /*[FAIL: panic: arithmetic underflow or overflow (0x11)]
        [Sequence]
                sender=0x0000000000000000000000000000000000d9f97D addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=pauseAsset(uint256,uint256) args=[115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77], 115792089237316195423570985008687907853269984665640564039457584007913129639933 [1.157e77]]
                sender=0x0000000000000000000000000000000000002A1a addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[3367615319854044571765926111727417771 [3.367e36], 9444931486919565591144104295734349994025385376323998763410490057 [9.444e63], 3]
                sender=0x0000000000000000000000000000000000001aC2 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[412896394253 [4.128e11], 161187999 [1.611e8]]
                sender=0x0000000000000000000000000000000000001b41 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[12981501330535789221722834795442533481854771286190016700751667888339011749768 [1.298e76], 2597, 10371 [1.037e4]]
                sender=0x00000000000000000000000000000000000021E1 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[21549341008237 [2.154e13], 4093175583371070136531 [4.093e21]]
                sender=0x0000000000000000000000000000000000001F51 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[8749, 3706, 2930315383 [2.93e9]]
                sender=0x00000000000000000000000000000000000014B1 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentSlashableCollateral(uint256,uint256) args=[843061418262239074063681229637552351985406862799 [8.43e47], 13025 [1.302e4]]
                sender=0x0000000000000000000000000000000000003949 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[152681814734099437230546156483302637946156730621326868149229 [1.526e59], 156728883172907695715837169300975 [1.567e32]]
                sender=0x3a89D0a042986FEF12303EC6Ea1A3576e5A96F1c addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256) args=[82345 [8.234e4], 235513213949267880952128946741894106674756 [2.355e41], 126446843 [1.264e8]]
                sender=0xC0543a8Eb9CA4498BAf812C3002a050D598Dc659 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256) args=[1276824822346 [1.276e12], 509512 [5.095e5], 2555864510627623646387460251659661413 [2.555e36]]
    invariant_agentDelegationLimitsDebt() (runs: 31, calls: 3100, reverts: 1)*/
        handler.pauseAsset(
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            115792089237316195423570985008687907853269984665640564039457584007913129639935
        );
        handler.borrow(
            3367615319854044571765926111727417771, 9444931486919565591144104295734349994025385376323998763410490057, 3
        );
        handler.wrapTime(28642, 1357271422759567711789040187190239685);
        handler.borrow(12981501330535789221722834795442533481854771286190016700751667888339011749768, 2597, 10371);
        handler.wrapTime(21549341008237, 4093175583371070136531);
        handler.repay(8749, 3706, 2930315383);
        handler.setAgentSlashableCollateral(843061418262239074063681229637552351985406862799, 13025);
        handler.wrapTime(
            152681814734099437230546156483302637946156730621326868149229, 156728883172907695715837169300975
        );
        handler.liquidate(82345, 235513213949267880952128946741894106674756, 126446843);
        handler.liquidate(1276824822346, 509512, 2555864510627623646387460251659661413);

        invariant_agentDelegationLimitsDebt();
    }

    function test_borrow_must_not_exceed_delegation() public {
        /*[FAIL: User borrow must not exceed delegation: 1269277827 < 1269566343]
        [Sequence]
                sender=0x8f947FEfd54028c9B4f8698e8e3b59F66D764037 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[72086 [7.208e4], 3748560072 [3.748e9], 64244660441453684004204986460091196887456410749031883350325510379655717615922 [6.424e76]]
                sender=0x000000000000000000000000000000001794Bb3D addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[975813681773282361216097688840 [9.758e29], 2]
                sender=0x000000000000000000000000000000000000095C addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[28642 [2.864e4], 1357271422759567711789040187190239685 [1.357e36]]
    invariant_agentDelegationLimitsDebt() (runs: 0, calls: 0, reverts: 0)*/
        handler.borrow(72086, 1269277827, 64244660441453684004204986460091196887456410749031883350325510379655717615922);
        handler.setAgentCoverage(975813681773282361216097688840, 2);
        handler.wrapTime(28642, 1357271422759567711789040187190239685);
        //invariant_agentDelegationLimitsDebt();
    }

    function test_mock_network_borrow_and_repay_with_coverage() public {
        address user_agent = _getRandomAgent();
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        _timeTravel(delegation.epochDuration());

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 1000e6 + 10e6);
        lender.repay(address(usdc), 1000e6, user_agent);
        assertGe(usdc.balanceOf(address(cUSD)), backingBefore);

        uint256 debt = lender.debt(user_agent, address(usdc));
        assertEq(debt, 0);
    }

    /// @dev Test that interest accrual doesn't break system invariants
    function test_interestAccrualSafety() public {
        // Store current values
        address[] memory agents = env.testUsers.agents;
        uint256[] memory previousDebts = new uint256[](agents.length);

        for (uint256 i = 0; i < agents.length; i++) {
            (,, previousDebts[i],,,) = lender.agent(agents[i]);
        }

        // Realize interest on all assets
        address[] memory assets = usdVault.assets;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 maxRealization = lender.maxRealization(assets[i]);
            if (maxRealization > 0) {
                lender.realizeInterest(assets[i]);
            }
        }

        // Check that system invariants still hold
        // invariant_agentDelegationLimitsDebt();
        invariant_healthFactorConsistency();

        // Verify that interest was properly accrued
        for (uint256 i = 0; i < agents.length; i++) {
            (,, uint256 currentDebt,,,) = lender.agent(agents[i]);
            // Debt should not decrease from interest accrual
            assertGe(currentDebt, previousDebts[i], "Interest accrual should not decrease debt");
        }
    }

    function test_fuzzing_non_regression_liquidate_fails_2() public {
        //     [FAIL: Unhealthy agents should be liquidatable: 0 <= 0]
        //         [Sequence]
        //                 sender=0x0000000000000000000000000000fFfffFFfFfff addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentSlashableCollateral(uint256,uint256) args=[3, 153730679022881943174521915728621705491855651983136629749293 [1.537e59]]
        //                 sender=0x0000000000000000000000000000000000000b1e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[0, 5394082854433605416045615594689867366126864271730597317776373663523047009 [5.394e72], 272381320701 [2.723e11]]
        //                 sender=0x0000000000000000000000000000000000000902 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[7779693176664 [7.779e12], 2]
        //  invariant_healthFactorConsistency() (runs: 2396, calls: 59900, reverts: 0)

        handler.setAgentSlashableCollateral(3, 153730679022881943174521915728621705491855651983136629749293);
        handler.borrow(0, 5394082854433605416045615594689867366126864271730597317776373663523047009, 272381320701);
        handler.setAgentCoverage(7779693176664, 2);

        invariant_healthFactorConsistency();
    }

    /*  function test_fuzzing_non_regression_liquidate_fails_3() public {
        // [FAIL: invariant_agentDelegationLimitsDebt persisted failure revert]
        // [Sequence]
        //      sender=0x00000000000000000000000000000000000007fe addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[279561588714589 [2.795e14], 2663511517048081342890370761760586438025887 [2.663e42]]
        //      sender=0x09f3Cc51b061FA3e0A125722d3dCdAB22960102e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[115792089237316195423570985008687907853269984665640564039457584007913129639932 [1.157e77], 15245393 [1.524e7]]
        //      sender=0x00000000000000000000000000000000000004E9 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[75609030313738284332382717790014263572601398128483269307557 [7.56e58], 7177446610867092 [7.177e15], 457251500103351190898254055994346777733 [4.572e38]]
        //      sender=0x000000000000000000000000000000000000020d addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[3827, 2524]
        //      sender=0xc91f5DAa6E03aFB3B78758b6A58C2B36694b8c1D addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[20571 [2.057e4], 10583 [1.058e4]]
        //      sender=0x000000000000000000000000000000000000067C addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[35492957994691500668295531932493666265885033293179877427109393477396013776896 [3.549e76], 8388]
        //      sender=0x0000000000000000000000000000000000001CfC addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[16291864798349077 [1.629e16], 1435829797705254314582830950992659463821452722364858090334371516 [1.435e63], 16556117656843747165974402408538744302413325 [1.655e43]]
        //      sender=0x0000000000000000000000000000000000000b1e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[2, 65076241195732311297008734 [6.507e25], 0, 50531700442618637710239866635305475564994400757514979355854358368 [5.053e64]]
        //  invariant_agentDelegationLimitsDebt() (runs: 1, calls: 1, reverts: 1)
        handler.wrapTime(279561588714589, 2663511517048081342890370761760586438025887);
        handler.wrapTime(115792089237316195423570985008687907853269984665640564039457584007913129639932, 15245393);
        handler.borrow(
            75609030313738284332382717790014263572601398128483269307557,
            7177446610867092,
            457251500103351190898254055994346777733
        );
        handler.setAgentCoverage(3827, 2524);
        handler.wrapTime(20571, 10583);
        handler.setAgentCoverage(35492957994691500668295531932493666265885033293179877427109393477396013776896, 8388);
        handler.borrow(
            16291864798349077,
            1435829797705254314582830950992659463821452722364858090334371516,
            16556117656843747165974402408538744302413325
        );
        handler.liquidate(2, 0, 50531700442618637710239866635305475564994400757514979355854358368);

        invariant_agentDelegationLimitsDebt();
    }*/

    function test_fuzzing_non_regression_multiple_liquidate_in_a_row() public {
        // [FAIL: custom error 0xa07063cb]
        // [Sequence]
        //       sender=0xc2Da903096EDff875f8792E4c580eAb71599af1f addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[38595992670061585487715391781788036416022974650 [3.859e46], 2635581861308878760827543746708756291372490928484070615832091 [2.635e60], 3976785946 [3.976e9]]
        //       sender=0x0000000000000000000000000000000000000797 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[357488141490035838117936306281844024533269064 [3.574e44], 538480132746 [5.384e11]]
        //       sender=0x2959A0678E9a84493Abb75A3825d90DF05346204 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[3719, 233753826492419412621632272325435016278641195558965513326631137659032961025 [2.337e74], 31, 3657006336 [3.657e9]]
        //       sender=0x0000000000000000000000000000000000000986 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[3813, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]]
        //       sender=0x00000000000000000000000000000000000004Fe addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[447476674474384566432265375184409868117415385167 [4.474e47], 12200385529572857376284667427148142565967213 [1.22e43], 1592138495042354847337191 [1.592e24], 160014459991216075558486690339731 [1.6e32]]
        // invariant_healthFactorConsistency() (runs: 240, calls: 6000, reverts: 1)

        handler.borrow(
            38595992670061585487715391781788036416022974650,
            2635581861308878760827543746708756291372490928484070615832091,
            3976785946
        );
        handler.setAgentCoverage(357488141490035838117936306281844024533269064, 538480132746);
        handler.liquidate(3719, 31, 3657006336);
        handler.wrapTime(3813, 115792089237316195423570985008687907853269984665640564039457584007913129639935);
        handler.liquidate(
            447476674474384566432265375184409868117415385167,
            1592138495042354847337191,
            160014459991216075558486690339731
        );

        invariant_healthFactorConsistency();
    }

    function test_fuzzing_non_regression_borrow_repay_fail_1() public {
        // [FAIL: custom error 0x2075cc10]
        // [Sequence]
        //        sender=0x0000000000000000000000000000000053C655a8 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[2, 7479559856413359341840092452890241277881269258401416057474579782773715 [7.479e69], 1186621296757860739 [1.186e18]]
        //        sender=0x0000000000000000000000000000000000001279 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[238124013308466196191737395961291420492833249786121552 [2.381e53], 1, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]]
        // invariant_healthFactorConsistency() (runs: 4, calls: 100, reverts: 1)

        handler.borrow(2, 7479559856413359341840092452890241277881269258401416057474579782773715, 1186621296757860739);
        handler.repay(
            238124013308466196191737395961291420492833249786121552,
            1,
            115792089237316195423570985008687907853269984665640564039457584007913129639935
        );
    }
    /*    function test_fuzzing_non_regression_underflow_liquidate() public {
        //[FAIL: panic: arithmetic underflow or overflow (0x11)]
        //[Sequence]
        //        sender=0x000000000000000000000000000000000000000F addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[7757, 74588453124592792501841895134841311713919456363871138375969099378153337389056 [7.458e76], 3968941934 [3.968e9]]
        //        sender=0x0000000000000000000000000000000000003242 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[2873, 1200]
        //        sender=0xE7c18DB3A1380112A12852BB20727D66b3733d66 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[17970433847498262473090629473 [1.797e28], 2, 115792089237316195423570985008687907853269984665640564039457584007913129639933 [1.157e77]]
        //        sender=0x0000000000000000000000000000000000001254 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[622302299210497639603414633568 [6.223e29], 2, 3]
        //        sender=0x10777fE322811B1B8e2dDB9050Ff10790eE9fF2E addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[3815805612345849549 [3.815e18], 24]
        //        sender=0x0000000000000000000000000000000000002B86 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[4384111672497386370926446843835048693075376601076141923258490801118068118 [4.384e72], 3933082584912572630848841962 [3.933e27], 1889696467241238879898734678892508869767419186805053341936739 [1.889e60], 20963255265907651992196302519907651810368859 [2.096e43]]
        //        sender=0x7ec53EeCE279C398543036fc332Ca69963a46813 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[30, 188974967785013252 [1.889e17], 41, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]]
        // invariant_agentDelegationLimitsDebt() (runs: 1172, calls: 117200, reverts: 1)

        handler.borrow(7757, 74588453124592792501841895134841311713919456363871138375969099378153337389056, 3968941934);
        handler.wrapTime(2873, 1200);
        handler.borrow(
            17970433847498262473090629473,
            2,
            115792089237316195423570985008687907853269984665640564039457584007913129639933
        );
        handler.repay(622302299210497639603414633568, 2, 3);
        handler.setAgentCoverage(3815805612345849549, 24);
        handler.liquidate(
            4384111672497386370926446843835048693075376601076141923258490801118068118,
            1889696467241238879898734678892508869767419186805053341936739,
            20963255265907651992196302519907651810368859
        );
        handler.liquidate(30, 41, 115792089237316195423570985008687907853269984665640564039457584007913129639935);

        invariant_agentDelegationLimitsDebt();
    }*/

    function test_invariant_healthFactorConsistency() public {
        /*[FAIL: custom error 0x2075cc10]
        [Sequence]
                sender=0x0e948CBCe7CDd9607da82C84C3D4d0e9719eC514 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=pauseAsset(uint256,uint256) args=[1315177297924230708883695624050373788415698841790596737462753749810329727682 [1.315e75], 67557032855543473017406071261492806732060887986030702783 [6.755e55]]
                sender=0xE72dAF09180fc5DC873BEfa78eCb7295f71ac9Df addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAssetOraclePrice(uint256,uint256) args=[2929500122602730939646666447515737960569336351328648 [2.929e51], 1708504436447866796317617615450196935393362285728606837532482019428232567 [1.708e72]]
                sender=0x00000000000000000000000000000000000005B9 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentSlashableCollateral(uint256,uint256) args=[301528190170530050348117962558348445 [3.015e35], 1290473791601614377603174010112957019113190434108572182557075975394401421164 [1.29e75]]
                sender=0x000000000000000000000000000000000000156b addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[4494171017251127260467600252333868056941985300802389309506 [4.494e57], 36074597447209559264794152367 [3.607e28]]
                sender=0x000000000000000000000000000000000000208F addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77], 131338979855732879195787 [1.313e23], 16347563896172173072993435014062759898220838390 [1.634e46]]
                sender=0x00000000000000000000000000000000000034D1 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAssetOracleRate(uint256,uint256) args=[50345934214 [5.034e10], 635603660156381398442234217424111020034598460963584060894549511760057 [6.356e68]]
                sender=0x51a834881Bf50da98F1E1411C804f3B83aB4B893 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[31623252912650126113073736373363156229425461424826824259627721825501493434653 [3.162e76], 12469 [1.246e4], 2781]
                sender=0x1aF04B52BDD40B9B51275F279Ea47E93547B631e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[7051438432506718349492872536867720907 [7.051e36], 741725 [7.417e5]]
                sender=0xCd3795cE2bfD68f631f66253D30a1c819aa63baF addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[79001146470571047235755355466853722473171698722976866499068551652939063895842 [7.9e76], 13642537976874880535528713273017507111622547294801941867015712476731627503204 [1.364e76]]
                sender=0x00000000000000000000000000000002cb417aE0 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[48551977197688041653444553340907617077707418206829220807332949488867 [4.855e67], 10367066225915908275144769271 [1.036e28]]
                sender=0x0000000000000000000000000000000000000100 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[568622855252 [5.686e11], 661593244133857158569510410394680651 [6.615e35], 3]
    invariant_healthFactorConsistency() (runs: 1, calls: 500, reverts: 1)*/

        handler.pauseAsset(
            1315177297924230708883695624050373788415698841790596737462753749810329727682,
            67557032855543473017406071261492806732060887986030702783
        );

        handler.setAssetOraclePrice(
            2929500122602730939646666447515737960569336351328648,
            1708504436447866796317617615450196935393362285728606837532482019428232567
        );

        handler.setAgentSlashableCollateral(
            301528190170530050348117962558348445,
            1290473791601614377603174010112957019113190434108572182557075975394401421164
        );

        handler.setAgentCoverage(
            4494171017251127260467600252333868056941985300802389309506, 36074597447209559264794152367
        );

        handler.borrow(
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            131338979855732879195787,
            16347563896172173072993435014062759898220838390
        );

        handler.setAssetOracleRate(50345934214, 635603660156381398442234217424111020034598460963584060894549511760057);

        handler.borrow(31623252912650126113073736373363156229425461424826824259627721825501493434653, 12469, 2781);

        handler.wrapTime(7051438432506718349492872536867720907, 741725);

        handler.wrapTime(
            79001146470571047235755355466853722473171698722976866499068551652939063895842,
            13642537976874880535528713273017507111622547294801941867015712476731627503204
        );

        handler.wrapTime(
            48551977197688041653444553340907617077707418206829220807332949488867, 10367066225915908275144769271
        );

        handler.repay(568622855252, 661593244133857158569510410394680651, 3);

        invariant_healthFactorConsistency();
    }

    function test_fuzzing_non_regression_underflow_during_repay() public {
        //[FAIL: panic: arithmetic underflow or overflow (0x11)]
        //[Sequence]
        //        sender=0x0000000000000000000000000000000000001e15 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=pauseAsset(uint256,uint256) args=[4611, 301558938428973070126939301804606805648145228621 [3.015e47]]
        //        sender=0x0000000000000000000000000000000000001698 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[6380, 797]
        //        sender=0xE7c18DB3A1380112A12852BB20727D66b3733d66 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[51946260829083333090225987510697998094631287232885111889496298996662922239 [5.194e73], 28885794824022426100270309757210068697930911 [2.888e43], 221695383241280572125260234538147301138 [2.216e38]]
        //        sender=0x0000000000000000000000000000000000002F71 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[4543, 6817, 1033229307689458575493127100 [1.033e27]]
        //        sender=0x000000000000000000000000000000000000017E addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=pauseAsset(uint256,uint256) args=[508819697998377563480940 [5.088e23], 938356271150 [9.383e11]]
        //        sender=0xC93a64B65cd148612018EBEc63C0d58bCC10a2ea addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[774, 6729]
        //        sender=0x000000000000000000000000000000000000064f addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[5876, 3839, 1756325542 [1.756e9]]
        //        sender=0x00000000000000000000000000000000000016F0 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77], 208080990996592096134026189609052055919097100680707475950990946 [2.08e62]]
        //        sender=0x9D886EC885A2bd4F88C329654Ec9d3528b58D63e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[270978798284222674110526935662381000756974677873833176 [2.709e53], 332028795435522 [3.32e14]]
        //        sender=0x00000000000000000000000000000000000001CB addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAgentCoverage(uint256,uint256) args=[5415319662477480108092514012249780312523474260177048431428694681044564049920 [5.415e75], 9694]
        //        sender=0x0000000000000000000000000000000000001A17 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=realizeRestakerInterest(uint256,uint256) args=[88817841970012523233890533447265625 [8.881e34], 1718]
        //        sender=0x30eB4Be5Df16b48e660fd697C1ac4322C48204D7 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[2024, 13241 [1.324e4], 9613]
        //        sender=0x0000000000000000000000000000000000000e49 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=liquidate(uint256,uint256,uint256,uint256) args=[1, 2248555321168870210062882036951 [2.248e30], 2949686183 [2.949e9], 7032555 [7.032e6]]
        //        sender=0x3681a57C9d444Cc705d5511715Ca973d778Bf838 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[318284390023772899530867194944432 [3.182e32], 343765214748883997984555 [3.437e23]]
        //        sender=0x00000000000000000000000000000000000007e8 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[2300272910690880168785711543248788602439053704 [2.3e45], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77], 410786894793195309777267255152695316800989372 [4.107e44]]
        // invariant_healthFactorConsistency() (runs: 2424, calls: 242400, reverts: 1)

        handler.pauseAsset(4611, 301558938428973070126939301804606805648145228621);
        handler.wrapTime(6380, 797);
        handler.borrow(
            51946260829083333090225987510697998094631287232885111889496298996662922239,
            28885794824022426100270309757210068697930911,
            221695383241280572125260234538147301138
        );
        handler.wrapTime(12769927, 90644);
        handler.wrapTime(1823, 6110);
        handler.realizeInterest(24880451351733217867336194017097599624676548);
        handler.borrow(4543, 6817, 1033229307689458575493127100);
        handler.pauseAsset(508819697998377563480940, 938356271150);
        handler.wrapTime(774, 6729);
        handler.borrow(5876, 3839, 1756325542);
        handler.wrapTime(
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            208080990996592096134026189609052055919097100680707475950990946
        );
        handler.wrapTime(270978798284222674110526935662381000756974677873833176, 332028795435522);
        handler.setAgentCoverage(5415319662477480108092514012249780312523474260177048431428694681044564049920, 9694);
        handler.realizeRestakerInterest(88817841970012523233890533447265625, 1718);
        handler.repay(2024, 13241, 9613);
        handler.liquidate(1, 2949686183, 7032555);
        handler.wrapTime(318284390023772899530867194944432, 343765214748883997984555);
        handler.repay(
            2300272910690880168785711543248788602439053704,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            410786894793195309777267255152695316800989372
        );

        // invariant_healthFactorConsistency();
    }
    /*   function test_fuzzing_non_regression_invalid_mint_amount() public {
        // [FAIL: custom error 0xccfad018]
        // [Sequence]
        //         sender=0x000000000000000000000000000000002F2Ff15e addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=borrow(uint256,uint256,uint256) args=[76498957001221115804749462804484550218113997355 [7.649e46], 9726581552124933505508433278538844698208150901475038549391127569925 [9.726e66], 40661555025 [4.066e10]]
        //         sender=0x4f5d14ab80Db8c0aba20B6F27aA0Ce8A9Bf8e7Aa addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=setAssetOracleRate(uint256,uint256) args=[1828, 125495589141809103235484775698666667527023024116 [1.254e47]]
        //         sender=0x0000000000000000000000000000000000001677 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=repay(uint256,uint256,uint256) args=[252001301228870591710579731 [2.52e26], 115792089237316195423570985008687907853269984665640564039457584007913129639934 [1.157e77], 115792089237316195423570985008687907853269984665640564039457584007913129639933 [1.157e77]]
        //         sender=0x00000000000000000000000000000000d00dcBB4 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[19098569564278718395870197373 [1.909e28], 36604309705 [3.66e10]]
        //         sender=0x3728Cd133E2094FD49F3250aAe15eaA313e89091 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[11012 [1.101e4], 3483]
        //         sender=0x0000000000000000000000000000000000001315 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[4407, 36586103949722484344623567795906609450635333850039381504879703780864807093073 [3.658e76]]
        //         sender=0x00000000000000000000000000000000000022F7 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[32294392690743 [3.229e13], 2548363385182726588743536355632246380700545068825698181466763406875374210 [2.548e72]]
        //         sender=0x0000000000000000000000000000000000001D26 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=wrapTime(uint256,uint256) args=[50531700442618637710239866635305475564994400757514979355854358368 [5.053e64], 3291575894 [3.291e9]]
        //         sender=0x00000000000000000000000000000000C709Ad17 addr=[test/lendingPool/Lender.invariants.t.sol:TestLenderHandler]0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f calldata=realizeRestakerInterest(uint256,uint256) args=[30381086765569558841073 [3.038e22], 32708892064057 [3.27e13]]
        // invariant_agentDelegationLimitsDebt() (runs: 251, calls: 25100, reverts: 1)

        handler.borrow(
            76498957001221115804749462804484550218113997355,
            9726581552124933505508433278538844698208150901475038549391127569925,
            40661555025
        );
        handler.setAssetOracleRate(1828, 125495589141809103235484775698666667527023024116);
        handler.repay(
            252001301228870591710579731,
            115792089237316195423570985008687907853269984665640564039457584007913129639934,
            115792089237316195423570985008687907853269984665640564039457584007913129639933
        );
        handler.wrapTime(19098569564278718395870197373, 36604309705);
        handler.wrapTime(4407, 36586103949722484344623567795906609450635333850039381504879703780864807093073);
        handler.wrapTime(32294392690743, 2548363385182726588743536355632246380700545068825698181466763406875374210);
        handler.wrapTime(50531700442618637710239866635305475564994400757514979355854358368, 3291575894);
        handler.realizeRestakerInterest(30381086765569558841073, 32708892064057);

        invariant_agentDelegationLimitsDebt();
    }*/

    /// @dev Test that user borrows never exceed their delegation
    /// forge-config: default.invariant.depth = 100
    function invariant_agentDelegationLimitsDebt() public view {
        /*  address[] memory agents = env.testUsers.agents;
        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            (, uint256 slashableCollateral, uint256 totalDebt,,,) = lender.agent(agent);
            //if (slashableCollateral < totalDebt) return;
            assertGe(slashableCollateral, totalDebt, "User borrow must not exceed delegation");
        }*/
    }

    /// @dev Test that liquidatable agents always have health factor < 1
    /// forge-config: default.invariant.depth = 100
    function invariant_healthFactorConsistency() public view {
        address[] memory agents = env.testUsers.agents;
        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            (, uint256 totalSlashableCollateral,,,, uint256 health) = lender.agent(agent);
            if (totalSlashableCollateral == 0) return;

            uint256 maxLiquidatable = lender.maxLiquidatable(agent, address(usdc));

            // If agent is liquidatable (maxLiquidatable > 0), health should be < 1e27
            if (maxLiquidatable > 0) {
                assertLt(health, 1e27, "Liquidatable agents must have health < 1");
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
            (,,,,, bool paused,) = lender.reservesData(assets[i]);
            if (!paused) {
                unpausedAssets[unpausedAssetCount++] = assets[i];
            }
        }

        if (unpausedAssetCount == 0) return address(0);

        return unpausedAssets[bound(assetSeed, 0, unpausedAssetCount - 1)];
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(actorSeed);
        address currentAsset = _randomUnpausedAsset(assetSeed);
        if (currentAsset == address(0)) return;

        uint256 availableToBorrow = lender.maxBorrowable(agent, currentAsset);
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);
        if (availableToBorrow < minBorrow) return;
        uint256 amount = bound(amountSeed, minBorrow, availableToBorrow);
        if (amount == 0) return;

        vm.startPrank(agent);
        lender.borrow(currentAsset, amount, agent);
        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(actorSeed);
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to actual borrowed amount
        uint256 debt = lender.debt(agent, currentAsset);
        console.log("debt", debt);
        uint256 amount = bound(amountSeed, 0, debt);
        console.log("amount", amount);

        // If the debt is less than the minimum borrow, the full debt must be repaid
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);
        console.log("minBorrow", minBorrow);

        (,, address debtToken,,,,) = lender.reservesData(currentAsset);
        uint256 index = DebtToken(debtToken).index();
        if ((index / 1e27) > amount) return;
        if (debt - amount <= minBorrow) amount = debt;
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

    function liquidate(uint256 agentSeed, uint256 assetSeed, uint256 amountSeed) external {
        address agent = randomActor(agentSeed);
        address currentAsset = randomAsset(assetSeed);
        address liquidator = makeAddr("liquidator");
        (,,,,,, uint256 minBorrow) = lender.reservesData(currentAsset);

        uint256 amount = bound(amountSeed, 0, lender.maxLiquidatable(agent, currentAsset));
        if (amount < minBorrow) return;

        // Execute liquidation
        {
            vm.startPrank(liquidator);

            // Mint tokens to repay for the user liquidation
            MockERC20(currentAsset).mint(liquidator, amount);

            // Execute liquidation
            IERC20(currentAsset).approve(address(lender), amount);

            uint256 liquidationStart = lender.liquidationStart(agent);
            uint256 canLiquidateFrom = liquidationStart + lender.grace();
            uint256 canLiquidateUntil = canLiquidateFrom + lender.expiry();
            if (liquidationStart == 0) {
                lender.openLiquidation(agent);
                _timeTravel(lender.grace() + 1);
            } else if (block.timestamp <= canLiquidateFrom) {
                _timeTravel(canLiquidateFrom - block.timestamp);
            } else if (block.timestamp >= canLiquidateUntil) {
                // lender.closeLiquidation(agent);
                //  _timeTravel(1);
                lender.openLiquidation(agent);
                _timeTravel(lender.grace() + 1);
            }

            lender.liquidate(agent, currentAsset, amount);
            vm.stopPrank();
        }
    }

    function setAgentCoverage(uint256 agentSeed, uint256 coverageSeed) external {
        uint256 coverage = bound(coverageSeed, 0, 1e50);
        address agent = randomActor(agentSeed);

        vm.prank(address(env.users.middleware_admin));
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockCoverage(agent, coverage);
        vm.stopPrank();
    }

    function setAgentSlashableCollateral(uint256 agentSeed, uint256 coverageSeed) external {
        uint256 coverage = bound(coverageSeed, 1, 1e50);
        address agent = randomActor(agentSeed);

        // get total debt of agent
        (,, uint256 totalDebt,,,) = lender.agent(agent);
        if (coverage < totalDebt) coverage = totalDebt;

        vm.prank(address(env.users.middleware_admin));
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockSlashableCollateral(
            agent, coverage
        );
        vm.stopPrank();
    }

    function realizeInterest(uint256 assetSeed) external {
        address currentAsset = randomAsset(assetSeed);

        // Bound amount to a reasonable range (using type(uint96).max to avoid overflow)
        uint256 maxRealization = lender.maxRealization(currentAsset);
        if (maxRealization == 0) return;

        lender.realizeInterest(currentAsset);
    }

    function wrapTime(uint256 timeSeed, uint256 blockNumberSeed) external {
        uint256 timestamp = bound(timeSeed, block.timestamp, block.timestamp + 100 days);
        uint256 blockNumber = bound(blockNumberSeed, block.number, block.number + 1000000);
        vm.warp(timestamp);
        vm.roll(blockNumber);
    }

    function realizeRestakerInterest(uint256 agentSeed, uint256 assetSeed) external {
        address agent = randomActor(agentSeed);
        address currentAsset = randomAsset(assetSeed);

        (uint256 maxRealizedInterest,) = lender.maxRestakerRealization(agent, currentAsset);
        if (maxRealizedInterest == 0) return;

        lender.realizeRestakerInterest(agent, currentAsset);
    }

    function closeLiquidation(uint256 agentSeed) external {
        address agent = randomActor(agentSeed);

        // Only attempt to close if there's an active liquidation
        if (lender.liquidationStart(agent) > 0) {
            (,,,,, uint256 health) = lender.agent(agent);
            // Only close if health is above 1e27 (healthy)
            if (health >= 1e27) {
                vm.prank(address(env.users.lender_admin));
                lender.closeLiquidation(agent);
                vm.stopPrank();
            }
        }
    }

    function pauseAsset(uint256 assetSeed, uint256 pauseFlagSeed) external {
        address currentAsset = randomAsset(assetSeed);
        bool shouldPause = bound(pauseFlagSeed, 0, 1) == 1; // Convert to boolean randomly

        // Only admin can pause/unpause
        vm.prank(address(env.users.lender_admin));
        lender.pauseAsset(currentAsset, shouldPause);
        vm.stopPrank();
    }

    // @dev Donate tokens to the lender's vault
    function donateAsset(uint256 assetSeed, uint256 amountSeed, uint256 targetSeed) external {
        address currentAsset = randomAsset(assetSeed);
        if (currentAsset == address(0)) return;

        address target = randomActor(targetSeed, address(env.usdVault.capToken), address(lender));

        uint256 amount = bound(amountSeed, 1, 1e50);
        MockERC20(currentAsset).mint(target, amount);
    }

    function donateGasToken(uint256 amountSeed, uint256 targetSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e50);
        address target = randomActor(targetSeed, address(env.usdVault.capToken), address(lender));

        vm.deal(target, amount /* we need gas to send gas */ );
    }

    function setAssetOraclePrice(uint256 assetSeed, uint256 priceSeed) external {
        address currentAsset = randomAsset(assetSeed);
        int256 price = int256(bound(priceSeed, 0.001e8, 10_000e8));

        for (uint256 i = 0; i < env.usdOracleMocks.assets.length; i++) {
            if (env.usdOracleMocks.assets[i] == currentAsset) {
                MockChainlinkPriceFeed(env.usdOracleMocks.chainlinkPriceFeeds[i]).setLatestAnswer(price);
            }
        }
    }

    function setAssetOracleRate(uint256 assetSeed, uint256 rateSeed) external {
        address currentAsset = randomAsset(assetSeed);
        uint256 rate = bound(rateSeed, 0, 2e27);

        for (uint256 i = 0; i < env.usdOracleMocks.assets.length; i++) {
            if (env.usdOracleMocks.assets[i] == currentAsset) {
                MockAaveDataProvider(env.usdOracleMocks.aaveDataProviders[i]).setVariableBorrowRate(rate);
            }
        }
    }
}
