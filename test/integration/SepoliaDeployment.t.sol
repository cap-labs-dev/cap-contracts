// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../contracts/interfaces/IFloatingMarket.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { TestnetERC20 } from "../../contracts/testnet/TestnetERC20.sol";
import { TestnetPriceFeed } from "../../contracts/testnet/TestnetPriceFeed.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { DeadShares } from "../../contracts/utils/DeadShares.sol";
import { DeploySepolia } from "../../script/DeploySepolia.s.sol";
import { InfraConfig } from "../../script/deploy/interfaces/DeployConfigs.sol";
import { CheckRoles } from "../../script/manage/CheckRoles.s.sol";
import { SepoliaActors } from "../../script/sepolia/SepoliaActors.sol";
import { MockAggregator } from "../shared/mocks/MockChainlinkFeeds.sol";
import { MockCreateX } from "../shared/mocks/MockCreateX.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Calls from the configured wallet without combining Foundry's prank and broadcast modes.
contract SepoliaScriptCaller {
    function run(DeploySepolia deployment) external returns (InfraConfig memory infra) {
        (, infra) = deployment.run();
    }

    function runWith(DeploySepolia deployment, bool writeOff, bool manifest)
        external
        returns (InfraConfig memory infra)
    {
        (, infra) = deployment.runWith(writeOff, manifest);
    }

    receive() external payable { }
}

/// @dev The deployment is not saved here, so the deployer is passed in rather than read from config.
contract SepoliaRoleChecker is CheckRoles {
    function check(InfraConfig memory infra, address deployer) external {
        IAccessManager manager = IAccessManager(infra.accessManager);
        _holder(manager, "ADMIN", CapRoles.ADMIN, infra.registry, true);
        _holder(manager, "REGISTRY", CapRoles.REGISTRY, infra.registry, true);
        _holder(manager, "ADMIN", CapRoles.ADMIN, deployer, true);
        _infraTable(manager, infra);
        require(mismatches == 0, "role mismatch");
    }
}

/// @dev Exposes the mnemonic guard without a broadcast context
contract ActorsHarness is SepoliaActors {
    function derive(string memory mnemonic, bool broadcasting) external {
        _deriveActors(mnemonic, broadcasting);
    }

    function deriveFrom(string memory mnemonic, uint32 offset, address deployer) external {
        _deriveActors(mnemonic, offset, false, deployer);
    }

    function actor(uint256 i) external view returns (address) {
        return allActors[i].addr;
    }
}

/// @notice Exercises the actual Sepolia script: the deployment, the mock tokens, and the whole
/// scenario storyline, run from an arbitrary wallet against mocked Sepolia externals.
contract SepoliaDeploymentTest is Test {
    DeploySepolia internal deployment;
    MockAggregator internal ethFeed;
    MockAggregator internal btcFeed;
    address internal deployer;

    function setUp() public {
        deployment = new DeploySepolia();
        deployer = makeAddr("testnet operator");
        vm.chainId(deployment.CHAIN_ID());
        vm.warp(7 days);
        vm.setEnv("SALT_NAMESPACE", vm.toString(deployment.DEFAULT_NAMESPACE()));
        vm.setEnv("EXPECT_DEPLOYER_ADMIN", "true");
        vm.etch(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, address(new MockCreateX()).code);
        ethFeed = _etchFeed(deployment.ETH_USD(), 3_000e8);
        btcFeed = _etchFeed(deployment.BTC_USD(), 100_000e8);
        vm.deal(deployer, 5 ether);
        vm.etch(deployer, address(new SepoliaScriptCaller()).code);
    }

    function _etchFeed(address at, int256 answer) private returns (MockAggregator feed) {
        vm.etch(at, address(new MockAggregator(8, answer, block.timestamp)).code);
        feed = MockAggregator(at);
        vm.store(address(feed), bytes32(0), bytes32(uint256(8)));
        feed.setAnswer(answer);
        feed.setUpdatedAt(block.timestamp);
    }

    function _run() internal returns (InfraConfig memory infra) {
        infra = SepoliaScriptCaller(payable(deployer)).runWith(deployment, false, false);
    }

    function _actor(uint256 index) internal view returns (address addr) {
        (addr,,) = deployment.allActors(index);
    }

    function _isMember(address manager, uint64 role, address who) internal view returns (bool member) {
        (member,) = IAccessManager(manager).hasRole(role, who);
    }

    // ── the storyline ─────────────────────────────────────────────────────────

    function test_storylineDeploysEverythingTheUiNeeds() public {
        string memory configBefore = vm.readFile("config/cap-v2.json");
        InfraConfig memory infra = SepoliaScriptCaller(payable(deployer)).run(deployment);
        assertEq(vm.readFile("config/cap-v2.json"), configBefore, "simulation does not persist addresses");

        new SepoliaRoleChecker().check(infra, deployer);
        Registry registry = Registry(infra.registry);
        assertEq(registry.marketsLength(), 4);
        assertEq(registry.underwritersLength(), 3);
        // 3 + 2 + 1 + 2 at creation, plus the two added to Atlas (one of them retired)
        assertEq(registry.tranchesLength(), 10);

        // every actor is funded and distinct
        for (uint256 i; i < deployment.ACTOR_COUNT(); ++i) {
            assertEq(_actor(i).balance > 0, true, "actor funded");
            for (uint256 j; j < i; ++j) {
                assertNotEq(_actor(i), _actor(j));
            }
        }
    }

    function test_marketsCarryDebtAndTheirOwnersGroupsBindThem() public {
        InfraConfig memory infra = _run();
        address manager = infra.accessManager;

        IBaseMarket atlas = IBaseMarket(deployment.atlas());
        IBaseMarket boreal = IBaseMarket(deployment.boreal());
        IBaseMarket cinderBtc = IBaseMarket(deployment.cinderBtc());
        IBaseMarket cinderWsteth = IBaseMarket(deployment.cinderWsteth());

        // debt where the storyline left it
        // 5,000 + 20,000 - 1,000, plus a few simulated hours of premium
        assertGe(atlas.totalDebt(), 24_000e18);
        assertLt(atlas.totalDebt(), 24_100e18);
        assertGt(boreal.totalDebt(), 4_500e18, "3,000 + 500 + 1,000 plus premium, loan #1 repaid");
        assertEq(FixedMarket(address(boreal)).debt(deployment.borealLoanB6()), 0, "F repaid in full");
        assertGe(cinderBtc.totalDebt(), 10_000e18);
        assertLt(cinderBtc.totalDebt(), 10_100e18);
        assertGt(cinderWsteth.totalDebt(), 0);
        assertGe(cinderWsteth.healthiness(), 1e27, "liquidation restored health");

        // owner groups administer their markets; Cinder is co-owned
        assertEq(registryOwnerRole(infra, address(atlas)), deployment.atlasOwners());
        assertEq(registryOwnerRole(infra, address(cinderBtc)), deployment.cinderOwners());
        assertTrue(_isMember(manager, deployment.cinderOwners(), _actor(0)), "owner A co-owns Cinder");
        assertTrue(_isMember(manager, deployment.cinderOwners(), _actor(2)));
        assertFalse(_isMember(manager, deployment.cinderOwners(), _actor(1)));

        // borrower group edits and swaps
        uint64 atlasA = deployment.atlasBorrowersA();
        assertTrue(_isMember(manager, atlasA, _actor(3)), "borrower A stays in group A");
        assertFalse(_isMember(manager, atlasA, _actor(4)), "borrower B was revoked");
        assertTrue(_isMember(manager, atlasA, _actor(5)), "borrower C was granted");
        assertEq(
            IAccessManager(manager).getTargetFunctionRole(address(atlas), IFloatingMarket.borrow.selector),
            deployment.atlasBorrowersB(),
            "Atlas now lends to group B"
        );
        (bool aCanBorrow,) = IAccessManager(manager).canCall(_actor(3), address(atlas), IFloatingMarket.borrow.selector);
        (bool dCanBorrow,) = IAccessManager(manager).canCall(_actor(6), address(atlas), IFloatingMarket.borrow.selector);
        assertFalse(aCanBorrow, "swapped-out group cannot draw");
        assertTrue(dCanBorrow, "swapped-in group can");
        assertEq(
            IAccessManager(manager).getTargetFunctionRole(address(boreal), IFloatingMarket.borrow.selector),
            deployment.borealBorrowersB()
        );
        assertEq(
            IAccessManager(manager).getTargetFunctionRole(address(cinderWsteth), IFloatingMarket.borrow.selector),
            deployment.cinderWstethBorrowersB()
        );
        assertTrue(_isMember(manager, deployment.cinderBtcBorrowers(), _actor(5)), "co-owner granted C");
        assertFalse(_isMember(manager, deployment.cinderBtcBorrowers(), _actor(8)), "co-owner revoked F");

        // owner reconfiguration landed
        assertEq(atlas.loanToValue(), 0.55e27);
        IBaseMarket.Tranche[] memory ts = atlas.tranches();
        assertEq(ts.length, 4, "a fourth tranche was added and the fifth removed");
        assertEq(ts[0].weight, 0.45e27);
        assertTrue(Tranche(deployment.atlasRetiredTranche()).killed(), "removed tranche is retired");
        assertEq(cinderBtc.loanToValue(), 0.45e27, "co-owner raised the LTV");
        assertEq(cinderBtc.liquidationThreshold(), 0.85e27, "guardian raised LT");
        assertEq(cinderBtc.buffer(), 0.15e27);
        assertEq(boreal.marketMultiplier(), 1.5e27);
        assertEq(FixedMarket(address(boreal)).maximumTermLimit(), 60 days);
        assertEq(atlas.targetHealth(), 1.3e27);
    }

    function registryOwnerRole(InfraConfig memory infra, address market) internal view returns (uint64) {
        return Registry(infra.registry).marketOwnerRole(market);
    }

    function test_depositorGroupsAndPoolsAreWiredAsNarrated() public {
        InfraConfig memory infra = _run();
        IAccessManager manager = IAccessManager(infra.accessManager);

        address senior = deployment.atlasTranches(0);
        address junior = deployment.atlasTranches(2);
        assertEq(manager.getTargetFunctionRole(senior, IERC4626.deposit.selector), deployment.atlasLpsV2());
        assertEq(manager.getTargetFunctionRole(junior, IERC4626.deposit.selector), type(uint64).max, "public junior");
        (bool bCanDeposit,) = manager.canCall(_actor(10), senior, IERC4626.deposit.selector);
        (bool eCanDeposit,) = manager.canCall(_actor(13), senior, IERC4626.deposit.selector);
        (bool poolCanDeposit,) = manager.canCall(deployment.uwWeth(), senior, IERC4626.deposit.selector);
        assertFalse(bCanDeposit, "depositor B lost deposit rights in the v2 swap");
        assertTrue(eCanDeposit, "depositor E gained them");
        assertTrue(poolCanDeposit, "the pool kept them");
        assertGt(Tranche(senior).balanceOf(_actor(10)), 0, "B keeps the shares it already holds");
        assertGt(Tranche(senior).balanceOf(_actor(13)), 0, "E deposited after the swap");

        Underwriter uwWeth = Underwriter(deployment.uwWeth());
        assertEq(uwWeth.defaultTranche(), senior);
        assertEq(uwWeth.registeredTranches().length, 2);
        assertGt(uwWeth.debt(senior), 0, "allocated to Atlas senior");
        assertGt(uwWeth.debt(deployment.borealTranches(0)), 0, "allocated to Boreal senior");
        assertGt(uwWeth.queuedShares(senior), 0, "async deallocation queued");
        assertGt(uwWeth.balanceOf(_actor(20)), 0);
        assertGt(uwWeth.balanceOf(_actor(21)), 0);

        Underwriter uwWbtc = Underwriter(deployment.uwWbtc());
        assertEq(manager.getTargetFunctionRole(address(uwWbtc), IERC4626.deposit.selector), type(uint64).max);
        assertGt(uwWbtc.balanceOf(_actor(22)), 0, "LP C deposited into the public pool");

        Underwriter uwWsteth = Underwriter(deployment.uwWsteth());
        assertEq(uwWsteth.registeredTranches().length, 1, "Atlas mezzanine was deregistered");
        assertEq(
            manager.getTargetFunctionRole(address(uwWsteth), Underwriter.allocate.selector),
            deployment.uwWstethAllocatorsV2()
        );
        (bool oldAllocator,) = manager.canCall(_actor(19), address(uwWsteth), Underwriter.allocate.selector);
        (bool newAllocator,) = manager.canCall(_actor(17), address(uwWsteth), Underwriter.allocate.selector);
        assertFalse(oldAllocator, "allocator C was swapped out");
        assertTrue(newAllocator, "allocator A was swapped in");
        assertFalse(uwWsteth.killed(), "the slashed pool survives the liquidation");
    }

    function test_liquidationSlashedCollateralToTheLiquidator() public {
        _run();
        TestnetERC20 mWsteth = deployment.mWsteth();
        address liquidator = _actor(23);
        assertGt(mWsteth.balanceOf(liquidator), 0, "liquidator holds slashed mwstETH");
        assertEq(uint256(deployment.wstethFeed().answer()), 2_150e8, "feed restored");
        assertEq(
            Stablecoin(IBaseMarket(deployment.cinderWsteth()).stablecoin()).badDebt(), 0, "no write-off by default"
        );
        // the junior tranche went first and is empty
        assertEq(Tranche(deployment.cinderWstethTranches(1)).totalAssets(), 0, "junior fully slashed");
    }

    function test_writeOffScenarioIsOptIn() public {
        InfraConfig memory infra = SepoliaScriptCaller(payable(deployer)).runWith(deployment, true, false);
        assertGt(Stablecoin(infra.stablecoin).badDebt(), 0, "guardian wrote unrecoverable debt off");
    }

    function test_exitsAreQueuedOrPaidAsNarrated() public {
        InfraConfig memory infra = _run();
        Tranche junior = Tranche(deployment.atlasTranches(2));
        assertEq(junior.balanceOf(_actor(13)), 0, "depositor E queued every junior share");
        assertGt(junior.redemptionQueue(), 0, "and it is waiting on the lock");
        Stablecoin cusd = Stablecoin(infra.stablecoin);
        assertGt(cusd.redemptionQueue(), 0, "E's cUSD request is queued");
        assertGt(deployment.mUsdc().balanceOf(_actor(12)), 0, "D got mUSDC back from the instant redeem");
        assertEq(Wrapper(infra.wrapper).balanceOf(_actor(12)), 3_000e18, "D holds 5,000 - 2,000 stcUSD");
    }

    function test_mockTokensMintOnlyForTheAdmin() public {
        _run();
        TestnetERC20 token = deployment.mUsdc();
        assertEq(token.owner(), deployer);
        assertEq(token.decimals(), 6);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.mint(stranger, 1e6);
        vm.prank(deployer);
        token.mint(stranger, 1e6);
        assertEq(token.balanceOf(stranger), 1e6);

        TestnetPriceFeed feed = deployment.wstethFeed();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        feed.setAnswer(1);
    }

    function test_deployedStackSupportsDepositWrapUnwrapAndRedeem() public {
        InfraConfig memory infra = _run();
        Stablecoin stablecoin = Stablecoin(infra.stablecoin);
        Wrapper wrapper = Wrapper(infra.wrapper);
        TestnetERC20 usdc = deployment.mUsdc();
        vm.prank(deployer);
        usdc.mint(deployer, 5e6);
        vm.startPrank(deployer);
        usdc.approve(infra.stablecoin, 5e6);
        uint256 cusd = stablecoin.deposit(5e6, deployer);
        stablecoin.approve(infra.wrapper, cusd);
        uint256 shares = wrapper.deposit(cusd, deployer);
        uint256 unwrapped = wrapper.redeem(shares, deployer, deployer);
        uint256 reserve = stablecoin.instantRedeem(unwrapped, deployer, deployer);
        vm.stopPrank();
        assertEq(cusd, 5e18);
        // premium has vested onto cUSD by now, so the round trip can lose a unit to rounding
        assertApproxEqAbs(reserve, 5e6, 1);
        assertEq(Wrapper(infra.wrapper).balanceOf(DeadShares.HOLDER), 1e18, "permanent seed remains");
    }

    function test_oraclePricesEveryCollateral() public {
        InfraConfig memory infra = _run();
        IOracle oracle = IOracle(infra.oracle);
        assertEq(oracle.price(address(deployment.mWeth())), 3_000e18);
        assertEq(oracle.price(address(deployment.mWbtc())), 100_000e18);
        assertEq(oracle.price(address(deployment.mWsteth())), 2_150e18);
    }

    function test_manifestIsWrittenOnRequest() public {
        SepoliaScriptCaller(payable(deployer)).runWith(deployment, false, true);
        string memory json = vm.readFile("config/sepolia-scenarios.json");
        assertEq(vm.parseJsonAddress(json, ".markets.atlasEthCredit.address"), deployment.atlas());
        assertEq(vm.parseJsonAddress(json, ".underwriters.capWethUnderwriter"), deployment.uwWeth());
        assertEq(vm.parseJsonUint(json, ".roles.atlasBorrowersB"), deployment.atlasBorrowersB());
        assertEq(vm.parseJsonAddress(json, ".actors.Liquidator"), _actor(23));
        vm.removeFile("config/sepolia-scenarios.json");
    }

    // ── the week after ────────────────────────────────────────────────────────

    /// @dev Seven days pass and Chainlink Sepolia never updates: the fallbacks keep every market
    /// priced, nothing becomes liquidatable, the long fixed loans are still live, and the routine
    /// calls the UI and keepers make keep working.
    function test_aWeekLaterWithSilentChainlinkFeedsNothingBreaks() public {
        InfraConfig memory infra = _run();
        uint256 deployedAt = block.timestamp;
        IOracle oracle = IOracle(infra.oracle);
        IBaseMarket[4] memory markets = [
            IBaseMarket(deployment.atlas()),
            IBaseMarket(deployment.boreal()),
            IBaseMarket(deployment.cinderBtc()),
            IBaseMarket(deployment.cinderWsteth())
        ];
        uint256[4] memory debtBefore;
        for (uint256 i; i < 4; ++i) {
            debtBefore[i] = markets[i].totalDebt();
        }

        vm.warp(deployedAt + 7 days);

        // the real feeds are now a week stale; the oracle falls through to the admin fallbacks
        assertEq(oracle.price(address(deployment.mWeth())), 3_000e18, "ETH priced by the fallback");
        assertEq(oracle.price(address(deployment.mWbtc())), 100_000e18, "BTC priced by the fallback");
        assertEq(oracle.price(address(deployment.mWsteth())), 2_150e18);

        for (uint256 i; i < 4; ++i) {
            // floating debt grows with the index; fixed loans charged their premium up front
            if (i == 1) assertEq(markets[i].totalDebt(), debtBefore[i], "fixed debt is flat until extended");
            else assertGt(markets[i].totalDebt(), debtBefore[i], "floating interest accrued");
            assertLt(markets[i].totalDebt(), debtBefore[i] * 102 / 100, "but less than 2% in a week");
            assertGe(markets[i].healthiness(), 1.5e27, "every market stays well above liquidation");
            assertEq(markets[i].maxLiquidatable(), 0, "nothing to liquidate");
            assertGt(markets[i].availableCredit(), 0, "and borrowing is still open");
        }

        FixedMarket boreal = FixedMarket(deployment.boreal());
        assertGt(boreal.expiry(deployment.borealLoanB5()), block.timestamp, "E's 14-day loan is live");
        assertGt(boreal.expiry(deployment.borealLoanB1()), block.timestamp, "A's 10-day loan is live");
        assertApproxEqAbs(
            boreal.expiry(deployment.borealLoanB5()), deployedAt + 14 days, 3 hours, "7 + 7 days from 8.4"
        );
        assertApproxEqAbs(boreal.expiry(deployment.borealLoanB1()), deployedAt + 10 days, 3 hours, "10 days from 8.6");

        // routine calls still go through: premium realisation, a deposit, a pool report, a claim
        FloatingMarket(deployment.atlas()).chargePremium();
        address senior = deployment.atlasTranches(0);
        TestnetERC20 weth = deployment.mWeth();
        vm.startPrank(_actor(9));
        weth.approve(senior, 1e18);
        Tranche(senior).deposit(1e18, _actor(9));
        assertGt(Tranche(senior).claim(_actor(9)), 0, "a week of premium has vested");
        vm.stopPrank();
        Underwriter uwWeth = Underwriter(deployment.uwWeth());
        vm.prank(deployer);
        uwWeth.report(senior);

        // and the wstETH sandbox can be liquidated again on purpose, but only on purpose
        TestnetPriceFeed wstethFeed = deployment.wstethFeed();
        vm.prank(deployer);
        wstethFeed.setAnswer(1_075e8);
        assertGt(markets[3].maxLiquidatable(), 0, "a 50% wstETH crash reopens the sandbox");
    }

    // ── guards ────────────────────────────────────────────────────────────────

    function test_staleFeedIsRejectedBeforeDeployment() public {
        ethFeed.setUpdatedAt(block.timestamp - deployment.FEED_MAX_AGE() - 1);
        vm.expectRevert("stale ETH/USD feed");
        _run();
    }

    function test_deadBtcFeedIsRejectedBeforeDeployment() public {
        btcFeed.setAnswer(0);
        vm.expectRevert("invalid BTC/USD price");
        _run();
    }

    function test_wrongChainIsRejected() public {
        vm.chainId(1);
        vm.expectRevert("Sepolia only");
        _run();
    }

    function test_forgeDefaultSenderIsRejected() public {
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert("no deployer: pass a wallet or --sender");
        deployment.run();
    }

    function test_underfundedDeployerIsRejected() public {
        vm.deal(deployer, 0.1 ether);
        vm.expectRevert("deployer cannot fund the actors");
        _run();
    }

    function test_usedNamespaceIsRejected() public {
        _run();
        vm.expectRevert("namespace already used");
        _run();
    }

    function test_saveRejectsAnUndeployedNamespace() public {
        string memory configBefore = vm.readFile("config/cap-v2.json");
        vm.expectRevert("deployment incomplete");
        deployment.save();
        assertEq(vm.readFile("config/cap-v2.json"), configBefore);
    }

    function test_actorsMayShareTheDeployersPhraseFromAnOffset() public {
        ActorsHarness harness = new ActorsHarness();
        string memory mnemonic = harness.TEST_MNEMONIC();
        address account0 = vm.addr(vm.deriveKey(mnemonic, 0));
        vm.expectRevert("an actor index collides with the deployer; set ACTORS_INDEX_OFFSET");
        harness.deriveFrom(mnemonic, 0, account0);

        ActorsHarness shifted = new ActorsHarness();
        shifted.deriveFrom(mnemonic, 1, account0);
        assertEq(shifted.actor(0), vm.addr(vm.deriveKey(mnemonic, 1)), "owner A is the phrase's account 1");
        assertEq(shifted.actor(23), vm.addr(vm.deriveKey(mnemonic, 24)), "liquidator is account 24");
        for (uint256 i; i < 24; ++i) {
            assertNotEq(shifted.actor(i), account0);
        }
    }

    function test_publicMnemonicIsRefusedForABroadcast() public {
        ActorsHarness harness = new ActorsHarness();
        string memory mnemonic = harness.TEST_MNEMONIC();
        harness.derive(mnemonic, false);
        vm.expectRevert("ACTORS_MNEMONIC is the public Foundry test mnemonic; set a private one");
        harness.derive(mnemonic, true);
    }
}
