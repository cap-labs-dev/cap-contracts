// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Registry } from "../../../../../contracts/cap/Registry.sol";
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { ChainlinkAdapter } from "../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../../contracts/cap/oracle/Oracle.sol";
import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../../contracts/deploy/service/DeployInfra.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../../../../../contracts/interfaces/IBeaconFactory.sol";
import { IFixedMarket } from "../../../../../contracts/interfaces/IFixedMarket.sol";
import { IFloatingMarket } from "../../../../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../../../../contracts/interfaces/IRegistry.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../../../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../../../../contracts/utils/CapRoles.sol";
import { MockAeraVault } from "../../../../../test/shared/mocks/MockAeraVault.sol";
import { MockAggregator } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Test, console } from "forge-std/Test.sol";

/// I24 production role table + N10 UUPS-on-beacon, on the real deploy path.
contract N3_UUPS_RoleTable is Test, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;
    address governor = makeAddr("governor");
    address keeper = makeAddr("keeper");
    address op = makeAddr("operator");
    address asset;
    address floating;
    address fixedM;
    address tranche;
    address underwriter;
    uint256 nZero;

    function setUp() public {
        users = UsersConfig({
            deployer: address(this),
            governor: governor,
            keeper: keeper,
            guardian: makeAddr("guardian"),
            admin: address(this),
            liquidator: makeAddr("liq"),
            stablecoinUnderlying: address(new MockERC20("USDC", "USDC", 18)),
            reserveVault: address(new MockAeraVault())
        });
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);

        asset = address(new MockERC20("wETH", "wETH", 18));
        MockAggregator feed = new MockAggregator(8, 2000e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 1 hours
        });
        vm.prank(governor);
        Oracle(infra.oracle).setSource(asset, hops);
        vm.prank(governor);
        Registry(infra.registry).assignOperator(op);

        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        vm.startPrank(keeper);
        address[] memory ts;
        (floating, ts) = Registry(infra.registry).createFloatingMarket(assets, w, "F", op, op);
        tranche = ts[0];
        (fixedM,) = Registry(infra.registry).createFixedMarket(assets, w, "X", op, op, 30 days, 1 days, 1 days);
        underwriter = Registry(infra.registry).createUnderwriter(asset, "U", "U", op);
        vm.stopPrank();
    }

    function _row(string memory label, address target, bytes4 sel) internal {
        uint64 r = IAccessManager(infra.accessManager).getTargetFunctionRole(target, sel);
        console.log(label, uint256(r));
        if (r == 0) nZero++;
    }

    function test_I24_roleTable() public {
        AccessManager m = AccessManager(infra.accessManager);
        console.log("--- infra ---");
        _row("Registry.assignOperator", infra.registry, IRegistry.assignOperator.selector);
        _row("Registry.createFloatingMarket", infra.registry, IRegistry.createFloatingMarket.selector);
        _row("Registry.createFixedMarket", infra.registry, IRegistry.createFixedMarket.selector);
        _row("Registry.createUnderwriter", infra.registry, IRegistry.createUnderwriter.selector);
        _row("Registry.upgradeToAndCall(ADMIN by design)", infra.registry, UUPSUpgradeable.upgradeToAndCall.selector);
        _row("BeaconFactory.create", infra.factory, IBeaconFactory.create.selector);
        _row("Stablecoin.mintCreditBacked", infra.stablecoin, IStablecoin.mintCreditBacked.selector);
        _row("Stablecoin.burnCreditBacked", infra.stablecoin, IStablecoin.burnCreditBacked.selector);
        _row("Stablecoin.recognizeBadDebt", infra.stablecoin, IStablecoin.recognizeBadDebt.selector);
        _row("Stablecoin.fundCreditBacked", infra.stablecoin, IStablecoin.fundCreditBacked.selector);
        _row("Stablecoin.invest", infra.stablecoin, IStablecoin.invest.selector);
        _row("Stablecoin.recall", infra.stablecoin, IStablecoin.recall.selector);
        _row("IRM.setLiquiditySlopes", infra.irm, IInterestRateModel.setLiquiditySlopes.selector);
        _row("IRM.setTermMultiplierSlope", infra.irm, IInterestRateModel.setTermMultiplierSlope.selector);
        _row("IRM.setLiquidationBonus", infra.irm, IInterestRateModel.setLiquidationBonus.selector);
        _row("IRM.setAveragingPeriod", infra.irm, IInterestRateModel.setAveragingPeriod.selector);
        _row("IRM.updateUnderwriterRate", infra.irm, IInterestRateModel.updateUnderwriterRate.selector);
        _row("IRM.updateMarketMultiplier", infra.irm, IInterestRateModel.updateMarketMultiplier.selector);
        _row("Oracle.setSource", infra.oracle, IOracle.setSource.selector);
        _row("Vault.upgradeToAndCall(ADMIN by design)", infra.vault, UUPSUpgradeable.upgradeToAndCall.selector);
        uint256 infraZero = nZero;
        console.log("--- floating market ---");
        address[2] memory mk = [floating, fixedM];
        for (uint256 i; i < 2; ++i) {
            if (i == 1) console.log("--- fixed market ---");
            _row("setLtv", mk[i], IBaseMarket.setLtv.selector);
            _row("setBuffer", mk[i], IBaseMarket.setBuffer.selector);
            _row("setLt", mk[i], IBaseMarket.setLt.selector);
            _row("setFixedCreditLimit", mk[i], IBaseMarket.setFixedCreditLimit.selector);
            _row("setTargetHealth", mk[i], IBaseMarket.setTargetHealth.selector);
            _row("setTranches", mk[i], IBaseMarket.setTranches.selector);
            _row("setTrancheWeights", mk[i], IBaseMarket.setTrancheWeights.selector);
            _row("setUnderwriterRate", mk[i], IBaseMarket.setUnderwriterRate.selector);
            _row("setMarketMultiplier", mk[i], IBaseMarket.setMarketMultiplier.selector);
            if (i == 0) {
                _row("borrow", mk[i], IFloatingMarket.borrow.selector);
                _row("liquidate", mk[i], IFloatingMarket.liquidate.selector);
                _row("writeOff", mk[i], IFloatingMarket.writeOff.selector);
            } else {
                _row("borrow", mk[i], IFixedMarket.borrow.selector);
                _row("borrowMore", mk[i], IFixedMarket.borrowMore.selector);
                _row("extend", mk[i], IFixedMarket.extend.selector);
                _row("extendAdmin", mk[i], IFixedMarket.extendAdmin.selector);
                _row("setTermLimits", mk[i], IFixedMarket.setTermLimits.selector);
                _row("liquidate", mk[i], IFixedMarket.liquidate.selector);
                _row("writeOff", mk[i], IFixedMarket.writeOff.selector);
            }
        }
        console.log("--- tranche ---");
        _row("Tranche.fund", tranche, ITranche.fund.selector);
        _row("Tranche.deposit", tranche, IERC4626.deposit.selector);
        _row("Tranche.mint", tranche, IERC4626.mint.selector);
        console.log("--- underwriter ---");
        _row("Underwriter.allocate", underwriter, IUnderwriter.allocate.selector);
        _row("Underwriter.deallocate", underwriter, IUnderwriter.deallocate.selector);
        _row("Underwriter.deallocateAsync", underwriter, IUnderwriter.deallocateAsync.selector);
        _row("Underwriter.finalizeDeallocateAsync", underwriter, IUnderwriter.finalizeDeallocateAsync.selector);
        _row("Underwriter.setDefaultTranche", underwriter, IUnderwriter.setDefaultTranche.selector);
        _row("Underwriter.addTranche", underwriter, IUnderwriter.addTranche.selector);
        _row("Underwriter.removeTranche", underwriter, IUnderwriter.removeTranche.selector);
        _row("Underwriter.report", underwriter, IUnderwriter.report.selector);
        _row("Underwriter.deposit", underwriter, IERC4626.deposit.selector);
        _row("Underwriter.mint", underwriter, IERC4626.mint.selector);
        console.log("role-0 rows (expect exactly the 2 upgradeToAndCall rows):", nZero);
        assertEq(nZero, 2);
        assertEq(infraZero, 2);
        // Registry holds every market owner role
        (bool has,) = m.hasRole(Registry(infra.registry).marketOwnerRole(floating), infra.registry);
        assertTrue(has);
        // and ADMIN, forever
        (has,) = m.hasRole(CapRoles.ADMIN, infra.registry);
        assertTrue(has);
        (has,) = m.hasRole(CapRoles.ADMIN, address(this));
        assertTrue(has, "the deploying contract is also ADMIN and never renounces");
    }

    function test_N10_upgradeToAndCallRevertsOnBeaconInstancesAndImplementations() public {
        address[4] memory targets = [tranche, underwriter, floating, fixedM];
        for (uint256 i; i < 4; ++i) {
            vm.prank(address(this)); // ADMIN
            vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(implems.tranche, "");
            vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
            UUPSUpgradeable(targets[i]).proxiableUUID();
        }
        address[4] memory impls = [implems.tranche, implems.underwriter, implems.floatingMarket, implems.fixedMarket];
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
            UUPSUpgradeable(impls[i]).upgradeToAndCall(implems.tranche, "");
        }
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Tranche(implems.tranche).initialize(infra.accessManager, asset, "x", "x", floating, infra.vault, infra.oracle);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Registry(implems.registry)
            .initialize(
                infra.accessManager,
                IRegistry.InitParams(
                    infra.stablecoin,
                    infra.vault,
                    infra.oracle,
                    infra.irm,
                    infra.factory,
                    infra.floatingMarketBeacon,
                    infra.fixedMarketBeacon,
                    infra.trancheBeacon,
                    infra.underwriterBeacon,
                    1,
                    1,
                    1
                )
            );
        // the live Registry proxy cannot be re-initialised either (init ran in the creation tx)
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Registry(infra.registry)
            .initialize(
                infra.accessManager,
                IRegistry.InitParams(
                    infra.stablecoin,
                    infra.vault,
                    infra.oracle,
                    infra.irm,
                    infra.factory,
                    infra.floatingMarketBeacon,
                    infra.fixedMarketBeacon,
                    infra.trancheBeacon,
                    infra.underwriterBeacon,
                    1,
                    1,
                    1
                )
            );
    }

    /// Registry.initialize needs ADMIN before init; DeployInfra grants it from address(this),
    /// which only works when the deploying contract is itself the AccessManager's initial admin.
    function test_L8_deployInfraRequiresDeployerToBeInitialAdmin() public {
        UsersConfig memory u = users;
        u.admin = makeAddr("coldMultisig");
        ImplementationsConfig memory im = _deployImplementations();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, address(this), CapRoles.ADMIN
            )
        );
        this.deployExternal(im, u);
    }

    function deployExternal(ImplementationsConfig memory im, UsersConfig memory u) external {
        _deployInfra(im, u);
    }
}
