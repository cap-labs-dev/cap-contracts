// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Registry } from "../../contracts/cap/Registry.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../../contracts/interfaces/IBeaconFactory.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { IFloatingMarket } from "../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { IStablecoin } from "../../contracts/interfaces/IStablecoin.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { InfraSerializer } from "../config/InfraSerializer.sol";
import { InfraConfig } from "../deploy/interfaces/DeployConfigs.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @title CheckRoles
/// @notice Print who holds each protocol role and which role every gated selector is wired to
/// @dev Reads `config/cap-v2.json`. Pass `MARKET`, `TRANCHE`, or `UNDERWRITER` to dump an instance.
contract CheckRoles is Script, InfraSerializer {
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;

    uint256 internal mismatches;

    function run() external {
        (, InfraConfig memory infra) = _readInfra();
        IAccessManager manager = IAccessManager(infra.accessManager);

        console.log("AccessManager", infra.accessManager);
        console.log("");

        _members(manager, infra);
        _infraTable(manager, infra);
        _optionalInstances(manager);

        console.log("");
        if (mismatches == 0) {
            console.log("roles match the table");
        } else {
            console.log("mismatches", mismatches);
            revert("roles drifted");
        }
    }

    function _members(IAccessManager manager, InfraConfig memory infra) internal {
        console.log("== contract holders ==");
        _holder(manager, "ADMIN", CapRoles.ADMIN, infra.registry, true);
        _holder(manager, "REGISTRY", CapRoles.REGISTRY, infra.registry, true);
        _holder(manager, "ADMIN", CapRoles.ADMIN, _readDeployer(), false);
        console.log("");
    }

    function _infraTable(IAccessManager manager, InfraConfig memory infra) internal {
        console.log("== infrastructure selectors ==");
        _wired(
            manager,
            "Stablecoin.mintCreditBacked",
            infra.stablecoin,
            IStablecoin.mintCreditBacked.selector,
            CapRoles.MARKET
        );
        _wired(
            manager,
            "Stablecoin.burnCreditBacked",
            infra.stablecoin,
            IStablecoin.burnCreditBacked.selector,
            CapRoles.MARKET
        );
        _wired(
            manager,
            "Stablecoin.recognizeBadDebtInCredit",
            infra.stablecoin,
            IStablecoin.recognizeBadDebtInCredit.selector,
            CapRoles.MARKET
        );
        _wired(
            manager,
            "Stablecoin.fundCreditBacked",
            infra.stablecoin,
            IStablecoin.fundCreditBacked.selector,
            CapRoles.MARKET
        );
        _wired(
            manager,
            "Stablecoin.recognizeBadDebtInReserve",
            infra.stablecoin,
            IStablecoin.recognizeBadDebtInReserve.selector,
            CapRoles.GUARDIAN
        );
        _wired(manager, "Stablecoin.invest", infra.stablecoin, IStablecoin.invest.selector, CapRoles.KEEPER);
        _wired(manager, "Stablecoin.recall", infra.stablecoin, IStablecoin.recall.selector, CapRoles.KEEPER);
        _wired(
            manager,
            "Stablecoin.setReserveVault",
            infra.stablecoin,
            IStablecoin.setReserveVault.selector,
            CapRoles.GOVERNOR
        );

        _wired(
            manager,
            "IRM.updateUnderwriterRate",
            infra.irm,
            IInterestRateModel.updateUnderwriterRate.selector,
            CapRoles.MARKET
        );
        _wired(
            manager,
            "IRM.setLiquiditySlopes",
            infra.irm,
            IInterestRateModel.setLiquiditySlopes.selector,
            CapRoles.GOVERNOR
        );
        _wired(
            manager,
            "IRM.setTermMultiplierSlope",
            infra.irm,
            IInterestRateModel.setTermMultiplierSlope.selector,
            CapRoles.GOVERNOR
        );
        _wired(
            manager,
            "IRM.setLiquidationBonus",
            infra.irm,
            IInterestRateModel.setLiquidationBonus.selector,
            CapRoles.GOVERNOR
        );
        _wired(
            manager,
            "IRM.setAveragingPeriod",
            infra.irm,
            IInterestRateModel.setAveragingPeriod.selector,
            CapRoles.GOVERNOR
        );

        _wired(manager, "Oracle.setSource", infra.oracle, IOracle.setSource.selector, CapRoles.GOVERNOR);

        _wired(
            manager,
            "Registry.createChildRoles",
            infra.registry,
            IRegistry.createChildRoles.selector,
            CapRoles.WHITELISTED
        );
        _wired(
            manager,
            "Registry.createFloatingMarket",
            infra.registry,
            IRegistry.createFloatingMarket.selector,
            CapRoles.WHITELISTED
        );
        _wired(
            manager,
            "Registry.createFixedMarket",
            infra.registry,
            IRegistry.createFixedMarket.selector,
            CapRoles.WHITELISTED
        );
        _wired(
            manager,
            "Registry.createUnderwriter",
            infra.registry,
            IRegistry.createUnderwriter.selector,
            CapRoles.WHITELISTED
        );
        _wired(
            manager, "Registry.setDepositorRole", infra.registry, IRegistry.setDepositorRole.selector, CapRoles.PROTOCOL
        );
        _wired(
            manager, "Registry.setBorrowerRole", infra.registry, IRegistry.setBorrowerRole.selector, CapRoles.PROTOCOL
        );
        _wired(
            manager, "Registry.setAllocatorRole", infra.registry, IRegistry.setAllocatorRole.selector, CapRoles.PROTOCOL
        );

        _wired(manager, "Factory.create", infra.factory, IBeaconFactory.create.selector, CapRoles.REGISTRY);

        _wired(
            manager,
            "Beacon.floating.upgradeTo",
            infra.floatingMarketBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            CapRoles.ADMIN
        );
        _wired(
            manager,
            "Beacon.fixed.upgradeTo",
            infra.fixedMarketBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            CapRoles.ADMIN
        );
        _wired(
            manager,
            "Beacon.tranche.upgradeTo",
            infra.trancheBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            CapRoles.ADMIN
        );
        _wired(
            manager,
            "Beacon.underwriter.upgradeTo",
            infra.underwriterBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            CapRoles.ADMIN
        );
        console.log("");
    }

    function _optionalInstances(IAccessManager manager) internal {
        address market = vm.envOr("MARKET", address(0));
        address tranche = vm.envOr("TRANCHE", address(0));
        address underwriter = vm.envOr("UNDERWRITER", address(0));

        if (market != address(0)) {
            (, InfraConfig memory infra) = _readInfra();
            console.log("== market", market, "==");
            uint64 ownerRole = Registry(infra.registry).marketOwnerRole(market);
            _wired(manager, "Market.setLtv", market, IBaseMarket.setLtv.selector, ownerRole);
            _wired(manager, "Market.setTrancheWeights", market, IBaseMarket.setTrancheWeights.selector, ownerRole);
            _wired(manager, "Market.setMarketMultiplier", market, IBaseMarket.setMarketMultiplier.selector, ownerRole);
            _wired(manager, "Market.setUnderwriterRate", market, IBaseMarket.setUnderwriterRate.selector, ownerRole);
            _wired(manager, "Market.setDepositorRole", market, IBaseMarket.setDepositorRole.selector, ownerRole);
            _wired(manager, "Market.setTranches", market, IBaseMarket.setTranches.selector, CapRoles.REGISTRY);
            _wired(manager, "Market.setTargetHealth", market, IBaseMarket.setTargetHealth.selector, CapRoles.GOVERNOR);
            _wired(
                manager,
                "Market.setFixedCreditLimit",
                market,
                IBaseMarket.setFixedCreditLimit.selector,
                CapRoles.GOVERNOR
            );
            _wired(manager, "Market.setBuffer", market, IBaseMarket.setBuffer.selector, CapRoles.GUARDIAN);
            _wired(manager, "Market.setLt", market, IBaseMarket.setLt.selector, CapRoles.GUARDIAN);
            _dump(manager, "Market.borrow", market, IFloatingMarket.borrow.selector);
            _wired(manager, "Market.liquidate", market, IFloatingMarket.liquidate.selector, CapRoles.LIQUIDATOR);
            _wired(manager, "Market.writeOff", market, IFloatingMarket.writeOff.selector, CapRoles.GUARDIAN);
            if (manager.getTargetFunctionRole(market, IFixedMarket.borrowMore.selector) != CapRoles.ADMIN) {
                _dump(manager, "Fixed.borrowMore", market, IFixedMarket.borrowMore.selector);
                _dump(manager, "Fixed.extend", market, IFixedMarket.extend.selector);
                _wired(manager, "Fixed.extendAdmin", market, IFixedMarket.extendAdmin.selector, CapRoles.KEEPER);
                _wired(manager, "Fixed.setTermLimits", market, IFixedMarket.setTermLimits.selector, CapRoles.GOVERNOR);
            }
            console.log("");
        }

        if (tranche != address(0)) {
            console.log("== tranche", tranche, "==");
            uint64 depositor = manager.getTargetFunctionRole(tranche, IERC4626.deposit.selector);
            uint64 owner = manager.getRoleAdmin(depositor);
            _wired(manager, "Tranche.fund", tranche, ITranche.fund.selector, CapRoles.MARKET);
            _wired(manager, "Tranche.deposit", tranche, IERC4626.deposit.selector, depositor);
            _wired(manager, "Tranche.mint", tranche, IERC4626.mint.selector, depositor);
            console.log("  depositor role", depositor, "admin", owner);
            console.log("");
        }

        if (underwriter != address(0)) {
            console.log("== underwriter", underwriter, "==");
            uint64 curator = manager.getTargetFunctionRole(underwriter, IUnderwriter.addTranche.selector);
            _wired(manager, "Underwriter.addTranche", underwriter, IUnderwriter.addTranche.selector, curator);
            _wired(
                manager, "Underwriter.setAllocatorRole", underwriter, IUnderwriter.setAllocatorRole.selector, curator
            );
            console.log("  curator role", curator);
            console.log("");
        }
    }

    function _holder(IAccessManager manager, string memory role, uint64 roleId, address account, bool expected)
        internal
    {
        (bool holds,) = manager.hasRole(roleId, account);
        string memory line = string.concat(role, " ", _label(account), holds ? " yes" : " no");
        if (holds == expected) {
            console.log(line);
        } else {
            console.log(string.concat("!! ", line, " (expected ", expected ? "yes" : "no", ")"));
            mismatches++;
        }
    }

    function _wired(IAccessManager manager, string memory name, address target, bytes4 selector, uint64 expected)
        internal
    {
        uint64 actual = manager.getTargetFunctionRole(target, selector);
        string memory line = string.concat(name, " -> ", _roleName(actual));
        if (actual == expected) {
            console.log(line);
        } else {
            console.log(string.concat("!! ", line, " (expected ", _roleName(expected), ")"));
            mismatches++;
        }
    }

    function _dump(IAccessManager manager, string memory name, address target, bytes4 selector) internal view {
        uint64 actual = manager.getTargetFunctionRole(target, selector);
        console.log(string.concat(name, " -> ", _roleName(actual)), uint256(actual));
    }

    function _roleName(uint64 roleId) private pure returns (string memory name) {
        if (roleId == CapRoles.ADMIN) return "ADMIN";
        if (roleId == CapRoles.GUARDIAN) return "GUARDIAN";
        if (roleId == CapRoles.GOVERNOR) return "GOVERNOR";
        if (roleId == CapRoles.KEEPER) return "KEEPER";
        if (roleId == CapRoles.MARKET) return "MARKET";
        if (roleId == CapRoles.REGISTRY) return "REGISTRY";
        if (roleId == CapRoles.LIQUIDATOR) return "LIQUIDATOR";
        if (roleId == CapRoles.WHITELISTED) return "WHITELISTED";
        if (roleId == CapRoles.PROTOCOL) return "PROTOCOL";
        if (roleId == PUBLIC_ROLE) return "PUBLIC";
        return "OPERATOR";
    }

    function _label(address account) private view returns (string memory label) {
        if (account == _readDeployer()) return "deployer";
        if (account == _readAccount("timelock")) return "timelock";
        if (account == _readAccount("multisig")) return "multisig";
        label = _hex(account);
    }

    function _hex(address account) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint160 value = uint160(account);
        for (uint256 i = 41; i > 1; --i) {
            s[i] = hexSymbols[value & 0xf];
            value >>= 4;
        }
        return string(s);
    }
}
