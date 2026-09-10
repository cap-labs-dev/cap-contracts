// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MockAeraVault } from "../shared/mocks/MockAeraVault.sol";
import { MockAggregator } from "../shared/mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { ChainlinkAdapter } from "../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../contracts/cap/oracle/Oracle.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../contracts/deploy/service/DeployInfra.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Test } from "forge-std/Test.sol";

/// @title DeploymentTest
/// @notice Runs the deployment services the scripts run, and checks what came out.
///
/// Nothing exercised these before. They sit under `contracts/`, so they compile, but the only
/// callers are in `script/`, which the profile does not even build, and the test harness wires its
/// own copy of the same graph by hand. A contract could therefore be left out of the deployment
/// entirely, or left reachable by the wrong role, and the whole suite would still pass — which is
/// how the oracle came to be a constructor argument nobody supplied and a set of governance
/// setters nobody assigned. The harness's copy of the wiring is the thing under test everywhere
/// else; this is the only place the real one is.
contract DeploymentTest is Test, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig internal users;
    InfraConfig internal infra;

    address internal governor;
    address internal stranger;

    function setUp() public {
        governor = makeAddr("governor");
        stranger = makeAddr("stranger");

        users = UsersConfig({
            deployer: address(this),
            governor: governor,
            keeper: makeAddr("keeper"),
            guardian: makeAddr("guardian"),
            // the manager's own admin, so this contract can run the wiring step the deployer runs
            admin: address(this),
            liquidator: makeAddr("liquidator"),
            stablecoinUnderlying: address(new MockERC20("USD Coin", "USDC", 18)),
            reserveVault: address(new MockAeraVault())
        });

        ImplementationsConfig memory implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
    }

    // ── the oracle is part of the deployment ──────────────────────────────────

    /// @dev It used to be an address handed in from outside, which meant the real one was never
    /// built by anything that runs and never read by anything that could disagree with it.
    function test_theRegistryPointsAtAnOracleThisDeploymentBuilt() public view {
        assertEq(Registry(infra.registry).oracle(), infra.oracle, "the registry reads the deployed oracle");
        assertGt(infra.oracle.code.length, 0, "which is a contract rather than an address");
        assertGt(infra.chainlinkAdapter.code.length, 0, "and it has an adapter to read feeds through");
    }

    /// @dev The scale is the one thing composing prices puts at risk, and it is only safe if it
    /// matches the cUSD debt every price is compared against. Asserted on the deployed pair rather
    /// than on the constants, so a deployment that picked up a mismatched oracle would fail here.
    function test_theDeployedOracleAnswersInTheDeployedStablecoinsScale() public view {
        assertEq(
            IOracle(infra.oracle).DECIMALS(),
            Stablecoin(infra.stablecoin).decimals(),
            "a price is a cUSD value and carries cUSD's scale"
        );
    }

    /// @dev Initialisation is easy to leave off a proxy, and an oracle initialised against nothing
    /// would have no authority at all: every setter would revert and no asset could ever be
    /// priced, so no market could launch.
    function test_theOracleIsInitialisedAgainstTheDeployedAccessManager() public view {
        assertEq(IAccessManaged(infra.oracle).authority(), infra.accessManager, "answers to the deployed manager");
    }

    /// @dev End to end on what was deployed: a feed, through the deployed adapter, out of the
    /// deployed oracle, normalised on the way. The eight decimals are what a real USD feed
    /// reports, so the normalisation is live rather than a no-op.
    function test_theDeployedOracleAndAdapterPriceAFeedTogether() public {
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        address asset = makeAddr("wETH");

        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 1 hours
        });

        vm.prank(governor);
        Oracle(infra.oracle).setSource(asset, hops);

        uint256 answer = IOracle(infra.oracle).price(asset);

        assertEq(answer, 2000e18, "the feed's eight decimals normalised into the oracle's eighteen");
    }

    // ── and its setters answer to the right role ──────────────────────────────

    /// @dev A feed and its window decide what all collateral is worth, so they belong with the
    /// risk parameters under GOVERNOR. Unwired they fell through to the manager's ADMIN_ROLE,
    /// which is both a wider set and the wrong one: the governor who is meant to manage feeds
    /// could not, and whoever administers the manager could.
    function test_theOraclesSettersAnswerToTheGovernor() public view {
        bytes4[1] memory selectors = [Oracle.setSource.selector];

        for (uint256 i; i < selectors.length; ++i) {
            (bool governorMay,) = IAccessManager(infra.accessManager).canCall(governor, infra.oracle, selectors[i]);
            assertTrue(governorMay, "the governor manages feeds");

            (bool strangerMay,) = IAccessManager(infra.accessManager).canCall(stranger, infra.oracle, selectors[i]);
            assertFalse(strangerMay, "and nobody else does");
        }
    }

    function test_aStrangerCannotPointAnAssetAtTheirOwnFeed() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({ adapter: infra.chainlinkAdapter, payload: "", staleness: 1 hours });
        Oracle(infra.oracle).setSource(makeAddr("wETH"), hops);
    }

    /// @dev The averaging window sets how quickly a fixed borrow's utilisation catches up with
    /// reality, so shortening it is a rate change. Wired alongside the other rate parameters
    /// rather than left to fall through, same as the oracle's setters.
    function test_theAveragingPeriodAnswersToTheGovernor() public {
        (bool governorMay,) = IAccessManager(infra.accessManager)
            .canCall(governor, infra.irm, InterestRateModel.setAveragingPeriod.selector);
        assertTrue(governorMay, "a rate parameter, set by the governor");

        vm.prank(governor);
        InterestRateModel(infra.irm).setAveragingPeriod(2 hours);
        assertEq(InterestRateModel(infra.irm).averagingPeriod(), 2 hours, "and it takes effect");
    }

    /// @dev Yield is a deposit of real reserve, so anyone holding the underlying can vest it —
    /// the Aera vault included — without holding MARKET.
    function test_anyoneMayFundTheStablecoin() public {
        MockERC20 usdc = MockERC20(users.stablecoinUnderlying);
        usdc.mint(stranger, 10e18);

        vm.startPrank(stranger);
        usdc.approve(infra.stablecoin, 10e18);
        Stablecoin(infra.stablecoin).fund(10e18);
        vm.stopPrank();

        assertEq(Stablecoin(infra.stablecoin).remaining(), 10e18, "the deposit is now vesting");
    }
}
