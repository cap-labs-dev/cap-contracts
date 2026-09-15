// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { BeaconFactory } from "../../../../../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../../../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../../contracts/cap/Underwriter.sol";
import { BaseMarket } from "../../../../../../contracts/cap/market/BaseMarket.sol";
import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../../../contracts/cap/oracle/Oracle.sol";
import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../../../contracts/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../../../contracts/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../../../contracts/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../../../contracts/deploy/service/DeployInfra.sol";
import { IOracle } from "../../../../../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../../../../../contracts/interfaces/IRegistry.sol";
import { CapRoles } from "../../../../../../contracts/utils/CapRoles.sol";
import { MockAggregator } from "../../../../../../test/shared/mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Test, console } from "forge-std/Test.sol";

/// Port of round-1 F1_ProdRoleTable: build the role table by deploying through contracts/deploy/**
contract R2_L7_ProdRoleTable is Test, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig users;
    ImplementationsConfig implems;
    InfraConfig infra;
    AccessManager manager;

    address governor = makeAddr("governor");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address liquidator = makeAddr("liquidator");
    address owner = makeAddr("marketOwner");
    address borrower = makeAddr("borrower");
    address uwOp = makeAddr("uwOperator");

    MockERC20 usdc;
    MockERC20 weth;
    address floating;
    address fixedM;
    address underwriter;
    address[] fTranches;
    address[] xTranches;
    address extraTranche;

    struct Sel {
        string name;
        address target;
        bytes4 sel;
    }
    Sel[] sels;
    uint256 zeroCount;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        // production: deployer EOA must be the AccessManager admin, since _deployInfra calls grantRole
        users = UsersConfig({
            deployer: address(this),
            governor: governor,
            keeper: keeper,
            guardian: guardian,
            admin: address(this),
            liquidator: liquidator,
            stablecoinUnderlying: address(usdc),
            reserveVault: address(0)
        });
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
        manager = AccessManager(infra.accessManager);

        // governor: price feed + operators
        MockAggregator feed = new MockAggregator(8, 1e8, block.timestamp);
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feed)),
            staleness: 1 days
        });
        vm.startPrank(governor);
        Oracle(infra.oracle).setSource(address(weth), hops);
        Registry(infra.registry).assignOperator(owner);
        Registry(infra.registry).assignOperator(borrower);
        Registry(infra.registry).assignOperator(uwOp);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        vm.startPrank(keeper);
        (floating, fTranches) = Registry(infra.registry).createFloatingMarket(assets, w, "F", owner, borrower);
        (fixedM, xTranches) =
            Registry(infra.registry).createFixedMarket(assets, w, "X", owner, borrower, 30 days, 1 days, 1 days);
        underwriter = Registry(infra.registry).createUnderwriter(address(weth), "UW", "cUW", uwOp);
        vm.stopPrank();
        uint256[] memory w2 = new uint256[](2);
        w2[0] = 0.5e27;
        w2[1] = 0.5e27;
        vm.prank(owner);
        extraTranche = Registry(infra.registry).createTranche(floating, address(weth), w2);
    }

    function _roleName(uint64 r) internal pure returns (string memory) {
        if (r == 0) return "ADMIN";
        if (r == 1) return "GUARDIAN";
        if (r == 2) return "GOVERNOR";
        if (r == 3) return "KEEPER";
        if (r == 4) return "MARKET";
        if (r == 5) return "REGISTRY";
        if (r == 6) return "LIQUIDATOR";
        if (r == type(uint64).max) return "PUBLIC";
        return r >= 100 ? "OPERATOR/DEPOSITOR" : "?";
    }

    function _add(string memory n, address t, bytes4 s) internal {
        sels.push(Sel(n, t, s));
    }

    function _buildSelectorList() internal {
        address r = infra.registry;
        _add("Registry.assignOperator", r, Registry.assignOperator.selector);
        _add("Registry.createFloatingMarket", r, Registry.createFloatingMarket.selector);
        _add("Registry.createFixedMarket", r, Registry.createFixedMarket.selector);
        _add("Registry.createUnderwriter", r, Registry.createUnderwriter.selector);
        address s = infra.stablecoin;
        _add("Stablecoin.fundCreditBacked", s, Stablecoin.fundCreditBacked.selector);
        _add("Stablecoin.mintCreditBacked", s, Stablecoin.mintCreditBacked.selector);
        _add("Stablecoin.burnCreditBacked", s, Stablecoin.burnCreditBacked.selector);
        _add("Stablecoin.invest", s, Stablecoin.invest.selector);
        _add("Stablecoin.recall", s, Stablecoin.recall.selector);
        _add("Stablecoin.recognizeBadDebt", s, Stablecoin.recognizeBadDebt.selector);
        address i = infra.irm;
        _add("IRM.setLiquiditySlopes", i, InterestRateModel.setLiquiditySlopes.selector);
        _add("IRM.updateUnderwriterRate", i, InterestRateModel.updateUnderwriterRate.selector);
        _add("IRM.updateMarketMultiplier", i, InterestRateModel.updateMarketMultiplier.selector);
        _add("IRM.setTermMultiplierSlope", i, InterestRateModel.setTermMultiplierSlope.selector);
        _add("IRM.setLiquidationBonus", i, InterestRateModel.setLiquidationBonus.selector);
        _add("IRM.setAveragingPeriod", i, InterestRateModel.setAveragingPeriod.selector);
        _add("Oracle.setSource", infra.oracle, Oracle.setSource.selector);
        _add("BeaconFactory.create", infra.factory, BeaconFactory.create.selector);
        address f = floating;
        _add("FloatingMarket.borrow", f, FloatingMarket.borrow.selector);
        _add("FloatingMarket.liquidate", f, FloatingMarket.liquidate.selector);
        _add("FloatingMarket.writeOff", f, FloatingMarket.writeOff.selector);
        _add("FloatingMarket.setLtv", f, BaseMarket.setLtv.selector);
        _add("FloatingMarket.setBuffer", f, BaseMarket.setBuffer.selector);
        _add("FloatingMarket.setLt", f, BaseMarket.setLt.selector);
        _add("FloatingMarket.setFixedCreditLimit", f, BaseMarket.setFixedCreditLimit.selector);
        _add("FloatingMarket.setTargetHealth", f, BaseMarket.setTargetHealth.selector);
        _add("FloatingMarket.setTranches", f, BaseMarket.setTranches.selector);
        _add("FloatingMarket.setTrancheWeights", f, BaseMarket.setTrancheWeights.selector);
        _add("FloatingMarket.setUnderwriterRate", f, BaseMarket.setUnderwriterRate.selector);
        _add("FloatingMarket.setMarketMultiplier", f, FloatingMarket.setMarketMultiplier.selector);
        address x = fixedM;
        _add("FixedMarket.borrow", x, FixedMarket.borrow.selector);
        _add("FixedMarket.borrowMore", x, FixedMarket.borrowMore.selector);
        _add("FixedMarket.extend", x, FixedMarket.extend.selector);
        _add("FixedMarket.extendAdmin", x, FixedMarket.extendAdmin.selector);
        _add("FixedMarket.liquidate", x, FixedMarket.liquidate.selector);
        _add("FixedMarket.writeOff", x, FixedMarket.writeOff.selector);
        _add("FixedMarket.setTermLimits", x, FixedMarket.setTermLimits.selector);
        _add("FixedMarket.setLtv", x, BaseMarket.setLtv.selector);
        _add("FixedMarket.setBuffer", x, BaseMarket.setBuffer.selector);
        _add("FixedMarket.setLt", x, BaseMarket.setLt.selector);
        _add("FixedMarket.setFixedCreditLimit", x, BaseMarket.setFixedCreditLimit.selector);
        _add("FixedMarket.setTargetHealth", x, BaseMarket.setTargetHealth.selector);
        _add("FixedMarket.setTranches", x, BaseMarket.setTranches.selector);
        _add("FixedMarket.setTrancheWeights", x, BaseMarket.setTrancheWeights.selector);
        _add("FixedMarket.setUnderwriterRate", x, BaseMarket.setUnderwriterRate.selector);
        _add("FixedMarket.setMarketMultiplier", x, BaseMarket.setMarketMultiplier.selector);
        address t = fTranches[0];
        _add("Tranche(floating#0).fund", t, Tranche.fund.selector);
        _add("Tranche(floating#0).deposit", t, Tranche.deposit.selector);
        _add("Tranche(floating#0).mint", t, Tranche.mint.selector);
        _add("Tranche(fixed#0).fund", xTranches[0], Tranche.fund.selector);
        _add("Tranche(fixed#0).deposit", xTranches[0], Tranche.deposit.selector);
        _add("Tranche(createTranche).fund", extraTranche, Tranche.fund.selector);
        _add("Tranche(createTranche).deposit", extraTranche, Tranche.deposit.selector);
        _add("Tranche(createTranche).mint", extraTranche, Tranche.mint.selector);
        address u = underwriter;
        _add("Underwriter.addTranche", u, Underwriter.addTranche.selector);
        _add("Underwriter.removeTranche", u, Underwriter.removeTranche.selector);
        _add("Underwriter.allocate", u, Underwriter.allocate.selector);
        _add("Underwriter.deallocate", u, Underwriter.deallocate.selector);
        _add("Underwriter.deallocateAsync", u, Underwriter.deallocateAsync.selector);
        _add("Underwriter.finalizeDeallocateAsync", u, Underwriter.finalizeDeallocateAsync.selector);
        _add("Underwriter.setDefaultTranche", u, Underwriter.setDefaultTranche.selector);
        _add("Underwriter.report", u, Underwriter.report.selector);
        _add("Underwriter.deposit", u, Underwriter.deposit.selector);
        _add("Underwriter.mint", u, Underwriter.mint.selector);
    }

    function test_L7_prodRoleTable() public {
        _buildSelectorList();
        console.log("| contract.function | roleId | roleName |");
        for (uint256 k = 0; k < sels.length; k++) {
            uint64 r = manager.getTargetFunctionRole(sels[k].target, sels[k].sel);
            console.log(string.concat("| ", sels[k].name, " | ", vm.toString(r), " | ", _roleName(r), " |"));
            if (r == 0) zeroCount++;
        }
        console.log("selectors resolving to role 0 (ADMIN by omission):", zeroCount);
        // round-1 offenders
        assertEq(
            manager.getTargetFunctionRole(infra.irm, InterestRateModel.setAveragingPeriod.selector),
            CapRoles.GOVERNOR,
            "setAveragingPeriod"
        );
        assertEq(
            manager.getTargetFunctionRole(infra.oracle, Oracle.setSource.selector),
            CapRoles.GOVERNOR,
            "Oracle.setSource"
        );
        assertEq(zeroCount, 0, "no restricted selector may fall through to ADMIN");
    }

    /// Negative: Registry.initialize without the ADMIN grant to the precomputed registry address
    function test_L7_initializeWithoutAdmin_reverts() public {
        AccessManager am = new AccessManager(address(this));
        IRegistry.InitParams memory p = IRegistry.InitParams({
            stablecoin: infra.stablecoin,
            vault: infra.vault,
            oracle: infra.oracle,
            irm: infra.irm,
            factory: infra.factory,
            floatingMarketBeacon: infra.floatingMarketBeacon,
            fixedMarketBeacon: infra.fixedMarketBeacon,
            trancheBeacon: infra.trancheBeacon,
            underwriterBeacon: infra.underwriterBeacon,
            lt: 0.8e27,
            buffer: 0.1e27,
            targetHealth: 1.25e27
        });
        address registryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        // no grantRole(ADMIN, registryAddr) here
        (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.deployRegistry, (address(am), p)));
        assertFalse(ok, "initialize must revert without ADMIN");
        console.log("revert selector:");
        console.logBytes4(bytes4(ret));
        console.log("expected AccessManagerUnauthorizedAccount(address,uint64):");
        console.logBytes4(IAccessManager.AccessManagerUnauthorizedAccount.selector);
        console.log("precomputed registry addr:", registryAddr);
        assertEq(bytes4(ret), IAccessManager.AccessManagerUnauthorizedAccount.selector);
    }

    function deployRegistry(address am, IRegistry.InitParams memory p) external returns (address) {
        return _proxy(implems.registry, abi.encodeCall(Registry.initialize, (am, p)));
    }
}
