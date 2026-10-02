// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { DeadShares } from "../../contracts/utils/DeadShares.sol";
import { DeploySepolia } from "../../script/DeploySepolia.s.sol";
import { InfraConfig } from "../../script/deploy/interfaces/DeployConfigs.sol";
import { CheckRoles } from "../../script/manage/CheckRoles.s.sol";
import { MockAggregator } from "../shared/mocks/MockChainlinkFeeds.sol";
import { MockCreateX } from "../shared/mocks/MockCreateX.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

/// @dev Calls from the configured wallet without combining Foundry's prank and broadcast modes.
contract SepoliaScriptCaller {
    function run(DeploySepolia deployment) external returns (InfraConfig memory infra) {
        (, infra) = deployment.run();
    }
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

/// @notice Exercises the actual script, including broadcast sender handling and six-decimal USDC.
/// Deploys from an arbitrary wallet: the script is not tied to the team's testnet deployer.
contract SepoliaDeploymentTest is Test {
    DeploySepolia internal deployment;
    MockERC20 internal usdc;
    MockAggregator internal feed;
    address internal deployer;

    function setUp() public {
        deployment = new DeploySepolia();
        deployer = makeAddr("testnet operator");
        vm.chainId(deployment.CHAIN_ID());
        vm.warp(7 days);
        vm.setEnv("SALT_NAMESPACE", vm.toString(deployment.DEFAULT_NAMESPACE()));
        vm.setEnv("EXPECT_DEPLOYER_ADMIN", "true");
        vm.etch(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, address(new MockCreateX()).code);
        vm.etch(deployment.USDC(), address(new MockERC20("USD Coin", "USDC", 6)).code);
        vm.etch(deployment.WETH(), address(new MockERC20("Wrapped Ether", "WETH", 18)).code);
        vm.etch(deployment.ETH_USD(), address(new MockAggregator(8, 2500e8, block.timestamp)).code);
        feed = MockAggregator(deployment.ETH_USD());
        vm.store(address(feed), bytes32(0), bytes32(uint256(8)));
        feed.setAnswer(2500e8);
        feed.setUpdatedAt(block.timestamp);
        usdc = MockERC20(deployment.USDC());
        usdc.mint(deployer, 20e6);
        vm.deal(deployer, 0.05 ether);
        vm.etch(deployer, address(new SepoliaScriptCaller()).code);
    }

    function _run() internal returns (InfraConfig memory infra) {
        infra = SepoliaScriptCaller(deployer).run(deployment);
    }

    function test_scriptSeedsFromWalletConfiguresWethAndWhitelistsOnlyTheDeployer() public {
        string memory configBefore = vm.readFile("config/cap-v2.json");
        vm.recordLogs();
        InfraConfig memory infra = _run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(usdc.balanceOf(deployer), 19e6, "wallet pays exactly one USDC");
        assertEq(usdc.balanceOf(address(deployment)), 0, "script never needs funding");
        assertEq(usdc.balanceOf(infra.stablecoin), 1e6);
        assertEq(Stablecoin(infra.stablecoin).balanceOf(infra.wrapper), 1e18);
        assertEq(Stablecoin(infra.stablecoin).balanceOf(deployer), 0);
        assertEq(Wrapper(infra.wrapper).balanceOf(DeadShares.HOLDER), 1e18);
        assertEq(IOracle(infra.oracle).price(deployment.WETH()), 2500e18);
        assertEq(Registry(infra.registry).marketsLength(), 0);
        assertEq(Registry(infra.registry).underwritersLength(), 0);
        assertEq(Registry(infra.registry).tranchesLength(), 0);
        assertEq(vm.readFile("config/cap-v2.json"), configBefore, "simulation does not persist addresses");

        IAccessManager manager = IAccessManager(infra.accessManager);
        new SepoliaRoleChecker().check(infra, deployer);
        (bool admin,) = manager.hasRole(CapRoles.ADMIN, deployer);
        assertTrue(admin);
        (bool creator,) = manager.canCall(deployer, infra.registry, Registry.createFloatingMarket.selector);
        assertTrue(creator, "the testnet operator can create markets immediately");
        bytes32 granted = keccak256("RoleGranted(uint64,address,uint32,uint48,bool)");
        uint256 whitelistGrants;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == infra.accessManager && logs[i].topics[0] == granted
                    && uint256(logs[i].topics[1]) == CapRoles.WHITELISTED
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), deployer, "only the deployer is whitelisted");
                ++whitelistGrants;
            }
        }
        assertEq(whitelistGrants, 1);
    }

    function test_deployedStackSupportsDepositWrapUnwrapAndRedeem() public {
        InfraConfig memory infra = _run();
        Stablecoin stablecoin = Stablecoin(infra.stablecoin);
        Wrapper wrapper = Wrapper(infra.wrapper);
        vm.startPrank(deployer);
        usdc.approve(infra.stablecoin, 5e6);
        uint256 cusd = stablecoin.deposit(5e6, deployer);
        stablecoin.approve(infra.wrapper, cusd);
        uint256 shares = wrapper.deposit(cusd, deployer);
        uint256 unwrapped = wrapper.redeem(shares, deployer, deployer);
        uint256 reserve = stablecoin.instantRedeem(unwrapped, deployer, deployer);
        vm.stopPrank();
        assertEq(cusd, 5e18);
        assertEq(reserve, 5e6);
        assertEq(usdc.balanceOf(deployer), 19e6);
        assertEq(usdc.balanceOf(infra.stablecoin), 1e6, "permanent seed remains");
    }

    function test_staleFeedIsRejectedBeforeDeployment() public {
        feed.setUpdatedAt(block.timestamp - deployment.FEED_MAX_AGE() - 1);
        vm.expectRevert("stale ETH/USD feed");
        _run();
        assertEq(usdc.balanceOf(deployer), 20e6);
    }

    function test_nonpositiveFeedIsRejectedBeforeDeployment() public {
        feed.setAnswer(0);
        vm.expectRevert("invalid ETH/USD price");
        _run();
    }

    function test_futureFeedIsRejectedBeforeDeployment() public {
        feed.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert("invalid ETH/USD timestamp");
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

    function test_eachWalletGetsItsOwnStack() public {
        InfraConfig memory infra = _run();

        address other = makeAddr("second operator");
        usdc.mint(other, 1e6);
        vm.etch(other, address(new SepoliaScriptCaller()).code);
        InfraConfig memory second = SepoliaScriptCaller(other).run(deployment);

        assertNotEq(second.stablecoin, infra.stablecoin, "deployer-keyed salts give separate addresses");
        (bool admin,) = IAccessManager(second.accessManager).hasRole(CapRoles.ADMIN, other);
        assertTrue(admin, "the second wallet administers its own stack");
        (bool crossed,) = IAccessManager(second.accessManager).hasRole(CapRoles.ADMIN, deployer);
        assertFalse(crossed, "and not the first one's");
    }

    function test_insufficientSeedIsRejectedBeforeDeployment() public {
        usdc.burn(deployer, 19e6 + 1);
        vm.expectRevert("need 1 USDC for wrapper seed");
        _run();
    }

    function test_usedNamespaceIsRejectedBeforeSpendingMoreUsdc() public {
        _run();
        vm.expectRevert("namespace already used");
        _run();
        assertEq(usdc.balanceOf(deployer), 19e6);
    }

    function test_saveRejectsAnUndeployedNamespace() public {
        string memory configBefore = vm.readFile("config/cap-v2.json");
        vm.expectRevert("deployment incomplete");
        deployment.save();
        assertEq(vm.readFile("config/cap-v2.json"), configBefore);
    }
}
