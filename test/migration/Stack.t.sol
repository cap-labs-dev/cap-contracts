// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Oracle } from "../../contracts/cap/oracle/Oracle.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { IStablecoin } from "../../contracts/interfaces/IStablecoin.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { MockAggregator } from "../shared/mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { ChainlinkAdapter } from "../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { MigrationBase } from "./MigrationBase.sol";

/// @notice The v2 stack is deployed alongside the upgraded proxies and can mint through them.
contract StackTest is MigrationBase {
    function test_newStackPointsAtTheLiveProxies() public view {
        assertEq(Registry(infra.registry).stablecoin(), address(scoin));
        assertEq(Registry(infra.registry).wrapper(), address(wrapper));
        assertEq(InterestRateModel(infra.irm).stablecoin(), address(scoin));
        assertEq(IAccessManaged(infra.irm).authority(), infra.accessManager);
        assertEq(IAccessManaged(infra.registry).authority(), infra.accessManager);
        assertEq(IAccessManaged(infra.vault).authority(), infra.accessManager);
        assertEq(IAccessManaged(infra.oracle).authority(), infra.accessManager);
        assertGt(infra.chainlinkAdapter.code.length, 0);
        assertEq(IOracle(infra.oracle).DECIMALS(), scoin.decimals());
    }

    function test_infraRoleTableMatchesAGreenfieldDeploy() public view {
        IAccessManager manager = IAccessManager(infra.accessManager);

        _expectRole(manager, infra.stablecoin, IStablecoin.mintCreditBacked.selector, CapRoles.MARKET);
        _expectRole(manager, infra.stablecoin, IStablecoin.invest.selector, CapRoles.KEEPER);
        _expectRole(manager, infra.stablecoin, IStablecoin.setReserveVault.selector, CapRoles.GOVERNOR);
        _expectRole(manager, infra.irm, IInterestRateModel.setAveragingPeriod.selector, CapRoles.GOVERNOR);
        _expectRole(manager, infra.oracle, IOracle.setSource.selector, CapRoles.GOVERNOR);
        _expectRole(manager, infra.registry, IRegistry.createFloatingMarket.selector, CapRoles.WHITELISTED);
        _expectRole(manager, infra.registry, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.stablecoin, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.vault, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.oracle, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.irm, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.factory, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
        _expectRole(manager, infra.wrapper, UUPSUpgradeable.upgradeToAndCall.selector, CapRoles.ADMIN);
    }

    function test_strangerCannotUpgradeTheMigratedProxies() public {
        address stub = address(new StablecoinImplStub());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(stub, "");
    }

    function test_newStackCanOpenAMarketAndMintCreditOnTheLiveCusd() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);

        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 3650 days
        });
        vm.prank(governor);
        Oracle(infra.oracle).setSource(address(weth), hops);

        IAccessManager manager = IAccessManager(infra.accessManager);
        manager.grantRole(CapRoles.WHITELISTED, address(this), 0);
        manager.grantRole(CapRoles.MARKET, address(this), 0);

        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = address(this);
        uint64 ownerRole = Registry(infra.registry).createChildRoles(CapRoles.GOVERNOR, members)[0];

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e27;

        (address market, address[] memory tranches) =
            Registry(infra.registry).createFloatingMarket(assets, weights, "migrated", ownerRole);

        assertTrue(Registry(infra.registry).isMarket(market));
        assertEq(tranches.length, 1);

        uint256 supplyBefore = scoin.totalSupply();
        scoin.mintCreditBacked(alice, 10e18);

        assertEq(scoin.balanceOf(alice), 10e18);
        assertEq(scoin.creditBackedSupply(), 10e18);
        assertEq(scoin.totalSupply(), supplyBefore + 10e18);
        assertEq(InterestRateModel(infra.irm).stablecoin(), address(scoin));
    }

    function _expectRole(IAccessManager manager, address target, bytes4 selector, uint64 expected) private view {
        assertEq(manager.getTargetFunctionRole(target, selector), expected);
    }
}

/// @dev Empty UUPS target so a stranger upgrade attempt has something to point at
contract StablecoinImplStub is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override { }
}
