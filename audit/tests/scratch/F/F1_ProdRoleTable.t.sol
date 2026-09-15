// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, console } from "forge-std/Test.sol";

import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../contracts/deploy/service/DeployInfra.sol";
import { DeployLibs } from "../../../../contracts/deploy/service/DeployLibs.sol";

import { InterestRateModel } from "../../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../../../../contracts/interfaces/IBeaconFactory.sol";
import { IFixedMarket } from "../../../../contracts/interfaces/IFixedMarket.sol";
import { IFloatingMarket } from "../../../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { IStablecoin } from "../../../../contracts/interfaces/IStablecoin.sol";
import { ITranche } from "../../../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../../../contracts/utils/CapRoles.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { MockOracle } from "../../../../test/shared/mocks/MockOracle.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// WS-F / H9. Deploys through the PRODUCTION wiring in contracts/deploy/** (the exact contracts
/// script/DeployInfra.s.sol inherits), not through test/shared/CapDeployer.sol, and pins the role
/// every `restricted` selector resolves to.
contract F1_ProdRoleTable is Test, DeployImplems, DeployInfra, DeployLibs, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;

    MockERC20 usdc;
    MockERC20 collateral;
    MockOracle mockOracle;
    Oracle prodOracle;
    AccessManager manager;

    address governor = makeAddr("governor");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address liquidator = makeAddr("liquidator");
    address marketOwner = makeAddr("marketOwner");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        collateral = new MockERC20("WETH", "WETH", 18);
        mockOracle = new MockOracle();
        mockOracle.setPrice(address(collateral), 1e18);

        // script/config/WalletUsersConfig.sol makes every role the broadcasting wallet; here the
        // deployer (this contract) is admin and the other roles are distinct so the gate is visible
        users = UsersConfig({
            deployer: address(this),
            governor: governor,
            keeper: keeper,
            guardian: guardian,
            admin: address(this),
            liquidator: liquidator,
            stablecoinUnderlying: address(usdc),
            stakedStablecoin: makeAddr("stcUSD"),
            oracle: address(mockOracle)
        });

        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
        manager = AccessManager(infra.accessManager);

        // The deploy pipeline never deploys an Oracle (users.oracle is an input). Stand one up on the
        // same AccessManager to see what its setters resolve to under production wiring.
        prodOracle = Oracle(
            address(new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (infra.accessManager))))
        );
    }

    function _role(address target, bytes4 sel) internal view returns (uint64) {
        return manager.getTargetFunctionRole(target, sel);
    }

    function _log(string memory what, address target, bytes4 sel) internal view {
        console.log("%s -> role %s", what, _role(target, sel));
    }

    // ------------------------------------------------------------------------------------------
    // H9: setAveragingPeriod is the only IRM setter missing from ConfigureAccessControl
    // ------------------------------------------------------------------------------------------

    /// FAILS on current code: production wiring leaves setAveragingPeriod at role 0 (ADMIN)
    function test_F1_setAveragingPeriod_isWiredToGovernorLikeTheOtherIrmSetters() public view {
        assertEq(_role(infra.irm, InterestRateModel.setLiquiditySlopes.selector), CapRoles.GOVERNOR, "slopes");
        assertEq(_role(infra.irm, InterestRateModel.setTermMultiplierSlope.selector), CapRoles.GOVERNOR, "term");
        assertEq(_role(infra.irm, InterestRateModel.setLiquidationBonus.selector), CapRoles.GOVERNOR, "bonus");
        assertEq(
            _role(infra.irm, InterestRateModel.setAveragingPeriod.selector),
            CapRoles.GOVERNOR,
            "setAveragingPeriod falls to ADMIN (role 0) by omission"
        );
    }

    /// FAILS on current code: the governor cannot call the setter the rest of the rate policy sits with
    function test_F1_governorCanSetAveragingPeriod() public {
        vm.prank(governor);
        InterestRateModel(infra.irm).setAveragingPeriod(10 minutes);
        assertEq(InterestRateModel(infra.irm).averagingPeriod(), 10 minutes);
    }

    // ------------------------------------------------------------------------------------------
    // Oracle: not deployed, not wired. All three setters resolve to ADMIN on the shared manager.
    // ------------------------------------------------------------------------------------------

    function test_F1_oracleSettersResolveToAdminAndGovernorIsLockedOut() public {
        assertEq(_role(address(prodOracle), IOracle.setSource.selector), 0, "setSource");
        assertEq(_role(address(prodOracle), IOracle.setBackup.selector), 0, "setBackup");
        assertEq(_role(address(prodOracle), IOracle.setChain.selector), 0, "setChain");

        IOracle.OracleData memory data = IOracle.OracleData({ adapter: address(1), payload: "", staleness: 1 hours });
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor));
        prodOracle.setSource(address(collateral), data);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        prodOracle.setSource(address(collateral), data);
    }

    // ------------------------------------------------------------------------------------------
    // Full production role table (printed), and the set of selectors that reach role 0
    // ------------------------------------------------------------------------------------------

    function test_F1_printProductionRoleTable() public {
        // operators + one of each instance so the dynamic wiring is included
        vm.startPrank(governor);
        Registry(infra.registry).assignOperator(marketOwner);
        Registry(infra.registry).assignOperator(borrower);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e27;

        vm.startPrank(keeper);
        (address fm, address[] memory fmTranches) =
            Registry(infra.registry).createMarket(assets, weights, "F", marketOwner, borrower);
        (address xm,) = Registry(infra.registry)
            .createFixedMarket(assets, weights, "X", marketOwner, borrower, 30 days, 1 days, 1 days);
        address uw = Registry(infra.registry).createUnderwriter(address(collateral), "UW", "UW", marketOwner);
        vm.stopPrank();
        address tr = fmTranches[0];

        console.log("--- shared infrastructure (ConfigureAccessControl) ---");
        _log("Registry.assignOperator", infra.registry, Registry.assignOperator.selector);
        _log("Registry.createMarket", infra.registry, Registry.createMarket.selector);
        _log("Registry.createFixedMarket", infra.registry, Registry.createFixedMarket.selector);
        _log("Registry.createUnderwriter", infra.registry, Registry.createUnderwriter.selector);
        _log("Registry.createTranche", infra.registry, Registry.createTranche.selector);
        _log("Registry.upgradeToAndCall", infra.registry, UUPSUpgradeable.upgradeToAndCall.selector);
        _log("BeaconFactory.create", infra.factory, IBeaconFactory.create.selector);
        _log("BeaconFactory.upgradeToAndCall", infra.factory, UUPSUpgradeable.upgradeToAndCall.selector);
        _log("Vault.upgradeToAndCall", infra.vault, UUPSUpgradeable.upgradeToAndCall.selector);
        _log("Stablecoin.mintCreditBacked", infra.stablecoin, IStablecoin.mintCreditBacked.selector);
        _log("Stablecoin.burnCreditBacked", infra.stablecoin, IStablecoin.burnCreditBacked.selector);
        _log("Stablecoin.recognizeBadDebt", infra.stablecoin, IStablecoin.recognizeBadDebt.selector);
        _log("Stablecoin.coverBadDebt", infra.stablecoin, IStablecoin.coverBadDebt.selector);
        _log("Stablecoin.upgradeToAndCall", infra.stablecoin, UUPSUpgradeable.upgradeToAndCall.selector);
        _log("IRM.setLiquiditySlopes", infra.irm, InterestRateModel.setLiquiditySlopes.selector);
        _log("IRM.setTermMultiplierSlope", infra.irm, InterestRateModel.setTermMultiplierSlope.selector);
        _log("IRM.setLiquidationBonus", infra.irm, InterestRateModel.setLiquidationBonus.selector);
        _log("IRM.setAveragingPeriod", infra.irm, InterestRateModel.setAveragingPeriod.selector);
        _log("IRM.updateUnderwriterRate", infra.irm, IInterestRateModel.updateUnderwriterRate.selector);
        _log("IRM.updateMarketMultiplier", infra.irm, IInterestRateModel.updateMarketMultiplier.selector);
        _log("IRM.upgradeToAndCall", infra.irm, UUPSUpgradeable.upgradeToAndCall.selector);
        _log("Oracle.setSource", address(prodOracle), IOracle.setSource.selector);
        _log("Oracle.setBackup", address(prodOracle), IOracle.setBackup.selector);
        _log("Oracle.setChain", address(prodOracle), IOracle.setChain.selector);
        _log("Oracle.upgradeToAndCall", address(prodOracle), UUPSUpgradeable.upgradeToAndCall.selector);

        console.log("--- floating market (Registry._configureMarketRoles) ---");
        _log("setLtv", fm, IBaseMarket.setLtv.selector);
        _log("setTrancheWeights", fm, IBaseMarket.setTrancheWeights.selector);
        _log("setMarketMultiplier", fm, IBaseMarket.setMarketMultiplier.selector);
        _log("setUnderwriterRate", fm, IBaseMarket.setUnderwriterRate.selector);
        _log("borrow", fm, IFloatingMarket.borrow.selector);
        _log("setTargetHealth", fm, IBaseMarket.setTargetHealth.selector);
        _log("setFixedCreditLimit", fm, IBaseMarket.setFixedCreditLimit.selector);
        _log("setBuffer", fm, IBaseMarket.setBuffer.selector);
        _log("setLt", fm, IBaseMarket.setLt.selector);
        _log("writeOff", fm, IFloatingMarket.writeOff.selector);
        _log("liquidate", fm, IFloatingMarket.liquidate.selector);
        _log("setTranches", fm, IBaseMarket.setTranches.selector);
        _log("setStakedStablecoin", fm, IBaseMarket.setStakedStablecoin.selector);

        console.log("--- fixed market ---");
        _log("borrow(3)", xm, IFixedMarket.borrow.selector);
        _log("borrowMore", xm, IFixedMarket.borrowMore.selector);
        _log("extend", xm, IFixedMarket.extend.selector);
        _log("extendAdmin", xm, IFixedMarket.extendAdmin.selector);
        _log("setTermLimits", xm, IFixedMarket.setTermLimits.selector);
        _log("liquidate(3)", xm, IFixedMarket.liquidate.selector);
        _log("writeOff(1)", xm, IFixedMarket.writeOff.selector);

        console.log("--- tranche ---");
        _log("setVestingPeriod", tr, ITranche.setVestingPeriod.selector);
        _log("slash", tr, ITranche.slash.selector);
        _log("notifyPremium", tr, ITranche.notifyPremium.selector);
        _log("deposit", tr, IERC4626.deposit.selector);
        _log("mint", tr, IERC4626.mint.selector);

        console.log("--- underwriter ---");
        _log("allocate", uw, IUnderwriter.allocate.selector);
        _log("deallocate", uw, IUnderwriter.deallocate.selector);
        _log("deallocateAsync", uw, IUnderwriter.deallocateAsync.selector);
        _log("finalizeDeallocateAsync", uw, IUnderwriter.finalizeDeallocateAsync.selector);
        _log("setDefaultTranche", uw, IUnderwriter.setDefaultTranche.selector);
        _log("setVestingPeriod", uw, IUnderwriter.setVestingPeriod.selector);
        _log("report", uw, IUnderwriter.report.selector);
        _log("addTranche", uw, IUnderwriter.addTranche.selector);
        _log("removeTranche", uw, IUnderwriter.removeTranche.selector);
        _log("deposit", uw, IERC4626.deposit.selector);
        _log("mint", uw, IERC4626.mint.selector);

        console.log("--- role membership / delays ---");
        (bool m, uint32 d) = manager.hasRole(CapRoles.ADMIN, infra.registry);
        console.log("registry has ADMIN: %s delay %s", m, d);
        (m, d) = manager.hasRole(CapRoles.ADMIN, users.admin);
        console.log("users.admin has ADMIN: %s delay %s", m, d);
        (m, d) = manager.hasRole(CapRoles.MINTER, fm);
        console.log("market has MINTER: %s delay %s", m, d);
        console.log("target admin delay registry: %s", manager.getTargetAdminDelay(infra.registry));
        console.log(
            "floatingMarketBeacon owner == users.admin: %s",
            UpgradeableBeacon(infra.floatingMarketBeacon).owner() == users.admin
        );
        console.log(
            "trancheBeacon owner == users.admin: %s", UpgradeableBeacon(infra.trancheBeacon).owner() == users.admin
        );
    }

    /// Every role in production is granted with executionDelay == 0 and no target has an admin
    /// delay: there is no timelock anywhere in the deployed configuration. (Passes: documentary.)
    function test_F1_noDelaysAnywhere() public view {
        address[6] memory who = [infra.registry, users.admin, governor, keeper, guardian, liquidator];
        uint64[6] memory roles = [
            CapRoles.ADMIN, CapRoles.ADMIN, CapRoles.GOVERNOR, CapRoles.KEEPER, CapRoles.GUARDIAN, CapRoles.LIQUIDATOR
        ];
        for (uint256 i; i < who.length; ++i) {
            (bool member, uint32 delay) = manager.hasRole(roles[i], who[i]);
            assertTrue(member);
            assertEq(delay, 0);
        }
        assertEq(manager.getTargetAdminDelay(infra.registry), 0);
        assertEq(manager.getTargetAdminDelay(infra.stablecoin), 0);
        assertEq(manager.getTargetAdminDelay(infra.vault), 0);
        // beacons: plain Ownable, not managed at all
        assertEq(UpgradeableBeacon(infra.floatingMarketBeacon).owner(), users.admin);
        assertEq(UpgradeableBeacon(infra.fixedMarketBeacon).owner(), users.admin);
        assertEq(UpgradeableBeacon(infra.trancheBeacon).owner(), users.admin);
        assertEq(UpgradeableBeacon(infra.underwriterBeacon).owner(), users.admin);
    }
}
