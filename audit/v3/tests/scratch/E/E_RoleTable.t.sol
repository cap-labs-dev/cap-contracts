// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// WS-E / I40: programmatic role table. Deploys the full stack via CapDeployer, creates one
// floating market, one fixed market (two tranches each), one underwriter, a Wrapper, and reads
// AccessManager.getTargetFunctionRole(target, selector) for every `restricted` selector (plus
// the UUPS upgradeToAndCall selector on the 7 UUPS proxies and the beacons' upgradeTo).
// test_printRoleTable prints target/selector/role; test_noAdminByOmission asserts.

import { Registry } from "../../../../../contracts/cap/Registry.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
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
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { console } from "forge-std/console.sol";

contract E_RoleTable is CapDeployer {
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;

    struct Row {
        string instance;
        address target;
        bytes4 selector;
        string fn;
        uint64 expected; // role _configure* intends; 0 == ADMIN
        bool explicitlyWired; // false + role 0 == "by omission"
    }

    Row[] internal rows;

    address internal floating;
    address[] internal floatingTranches;
    address internal fixedM;
    address[] internal fixedTranches;
    address internal underwriter;
    address internal freshUnderwriter;
    address internal freshMarket;
    address internal wrapper;
    uint64 internal ownerRole;
    uint64 internal borrowerRole;
    uint64 internal curatorRole;
    uint64 internal allocatorRole;

    function setUp() public {
        _deployCap();
        (floating, floatingTranches) =
            _createMarket("E-floating", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        (fixedM, fixedTranches) =
            _createFixedMarket("E-fixed", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        ownerRole = _operatorRoleOf(defaultMarketOwner);
        borrowerRole = _operatorRoleOf(defaultBorrower);
        underwriter = address(_deployUnderwriter());
        curatorRole = _operatorRoleOf(address(this));
        allocatorRole = _allocatorRole(underwriter);

        // fresh instances with NO setBorrowerRole / setAllocatorRole / setDepositorRole calls
        freshUnderwriter = registry.createUnderwriter(address(collateral), "fresh", "FR", curatorRole);
        (freshMarket,) =
            registry.createFloatingMarket(_uniformAssets(2), capConfig.defaultTrancheWeights, "fresh-m", ownerRole);

        Wrapper impl = new Wrapper();
        wrapper = _deployProxy(
            address(impl), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(stablecoin)))
        );

        _buildRows();
    }

    function _add(string memory inst, address t, bytes4 s, string memory fn, uint64 exp, bool wired) internal {
        rows.push(Row(inst, t, s, fn, exp, wired));
    }

    function _buildRows() internal {
        bytes4 upg = UUPSUpgradeable.upgradeToAndCall.selector;
        // Registry
        _add(
            "Registry",
            address(registry),
            IRegistry.createChildRoles.selector,
            "createChildRoles",
            CapRoles.WHITELISTED,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.createFloatingMarket.selector,
            "createFloatingMarket",
            CapRoles.WHITELISTED,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.createFixedMarket.selector,
            "createFixedMarket",
            CapRoles.WHITELISTED,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.createUnderwriter.selector,
            "createUnderwriter",
            CapRoles.WHITELISTED,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.setDepositorRole.selector,
            "setDepositorRole",
            CapRoles.PROTOCOL,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.setBorrowerRole.selector,
            "setBorrowerRole",
            CapRoles.PROTOCOL,
            true
        );
        _add(
            "Registry",
            address(registry),
            IRegistry.setAllocatorRole.selector,
            "setAllocatorRole",
            CapRoles.PROTOCOL,
            true
        );
        _add("Registry", address(registry), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        _add(
            "Registry",
            address(registry),
            IRegistry.createTranche.selector,
            "createTranche (NOT restricted; inline hasRole)",
            CapRoles.ADMIN,
            false
        );
        // Stablecoin
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.mintCreditBacked.selector,
            "mintCreditBacked",
            CapRoles.MARKET,
            true
        );
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.burnCreditBacked.selector,
            "burnCreditBacked",
            CapRoles.MARKET,
            true
        );
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.recognizeBadDebtInCredit.selector,
            "recognizeBadDebtInCredit",
            CapRoles.MARKET,
            true
        );
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.fundCreditBacked.selector,
            "fundCreditBacked",
            CapRoles.MARKET,
            true
        );
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.recognizeBadDebtInReserve.selector,
            "recognizeBadDebtInReserve",
            CapRoles.GUARDIAN,
            true
        );
        _add("Stablecoin", address(stablecoin), IStablecoin.invest.selector, "invest", CapRoles.KEEPER, true);
        _add("Stablecoin", address(stablecoin), IStablecoin.recall.selector, "recall", CapRoles.KEEPER, true);
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.setReserveVault.selector,
            "setReserveVault",
            CapRoles.GOVERNOR,
            true
        );
        _add("Stablecoin", address(stablecoin), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        _add(
            "Stablecoin",
            address(stablecoin),
            IERC4626.deposit.selector,
            "deposit (NOT restricted)",
            CapRoles.ADMIN,
            false
        );
        _add("Stablecoin", address(stablecoin), IERC4626.mint.selector, "mint (NOT restricted)", CapRoles.ADMIN, false);
        _add(
            "Stablecoin", address(stablecoin), IStablecoin.fund.selector, "fund (NOT restricted)", CapRoles.ADMIN, false
        );
        _add(
            "Stablecoin",
            address(stablecoin),
            IStablecoin.coverBadDebt.selector,
            "coverBadDebt (NOT restricted)",
            CapRoles.ADMIN,
            false
        );
        // IRM
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.updateUnderwriterRate.selector,
            "updateUnderwriterRate",
            CapRoles.MARKET,
            true
        );
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.setLiquiditySlopes.selector,
            "setLiquiditySlopes",
            CapRoles.GOVERNOR,
            true
        );
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.setTermMultiplierSlope.selector,
            "setTermMultiplierSlope",
            CapRoles.GOVERNOR,
            true
        );
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.setLiquidationBonus.selector,
            "setLiquidationBonus",
            CapRoles.GOVERNOR,
            true
        );
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.setAveragingPeriod.selector,
            "setAveragingPeriod",
            CapRoles.GOVERNOR,
            true
        );
        _add("IRM", address(irm), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        _add(
            "IRM",
            address(irm),
            IInterestRateModel.updateLiquidityRate.selector,
            "updateLiquidityRate (NOT restricted)",
            CapRoles.ADMIN,
            false
        );
        // Oracle
        _add("Oracle", address(oracle), IOracle.setSource.selector, "setSource", CapRoles.GOVERNOR, true);
        _add("Oracle", address(oracle), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        // Vault
        _add("Vault", address(vault), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        // Wrapper
        _add("Wrapper", wrapper, upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        // BeaconFactory
        _add("BeaconFactory", address(beaconFactory), IBeaconFactory.create.selector, "create", CapRoles.REGISTRY, true);
        _add("BeaconFactory", address(beaconFactory), upg, "upgradeToAndCall (UUPS)", CapRoles.ADMIN, false);
        // Beacons
        _add(
            "FloatingBeacon",
            floatingMarketBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            "upgradeTo",
            CapRoles.ADMIN,
            true
        );
        _add("FixedBeacon", fixedMarketBeacon, UpgradeableBeacon.upgradeTo.selector, "upgradeTo", CapRoles.ADMIN, true);
        _add("TrancheBeacon", trancheBeacon, UpgradeableBeacon.upgradeTo.selector, "upgradeTo", CapRoles.ADMIN, true);
        _add(
            "UnderwriterBeacon",
            underwriterBeacon,
            UpgradeableBeacon.upgradeTo.selector,
            "upgradeTo",
            CapRoles.ADMIN,
            true
        );
        // Markets (floating and fixed get the identical _configureMarketRoles wiring)
        _marketRows("FloatingMarket", floating, true);
        _marketRows("FixedMarket", fixedM, true);
        _marketRows("FreshFloatingMarket(no setBorrowerRole)", freshMarket, false);
        // Tranches
        _trancheRows("Floating.T0", floatingTranches[0]);
        _trancheRows("Floating.T1", floatingTranches[1]);
        _trancheRows("Fixed.T0", fixedTranches[0]);
        _trancheRows("Fixed.T1", fixedTranches[1]);
        // Underwriter (configured) and fresh underwriter
        _underwriterRows("Underwriter", underwriter, true);
        _underwriterRows("FreshUnderwriter(no set*Role)", freshUnderwriter, false);
    }

    function _marketRows(string memory inst, address m, bool borrowerSet) internal {
        _add(inst, m, IBaseMarket.setTrancheWeights.selector, "setTrancheWeights", ownerRole, true);
        _add(inst, m, IBaseMarket.setLtv.selector, "setLtv", ownerRole, true);
        _add(inst, m, IBaseMarket.setMarketMultiplier.selector, "setMarketMultiplier", ownerRole, true);
        _add(inst, m, IBaseMarket.setUnderwriterRate.selector, "setUnderwriterRate", ownerRole, true);
        _add(inst, m, IBaseMarket.setBorrowerRole.selector, "setBorrowerRole", ownerRole, true);
        _add(inst, m, IBaseMarket.setDepositorRole.selector, "setDepositorRole", ownerRole, true);
        _add(inst, m, IBaseMarket.setTranches.selector, "setTranches", CapRoles.REGISTRY, true);
        _add(inst, m, IBaseMarket.setTargetHealth.selector, "setTargetHealth", CapRoles.GOVERNOR, true);
        _add(inst, m, IBaseMarket.setFixedCreditLimit.selector, "setFixedCreditLimit", CapRoles.GOVERNOR, true);
        _add(inst, m, IFixedMarket.setTermLimits.selector, "setTermLimits", CapRoles.GOVERNOR, true);
        _add(inst, m, IBaseMarket.setBuffer.selector, "setBuffer", CapRoles.GUARDIAN, true);
        _add(inst, m, IBaseMarket.setLt.selector, "setLt", CapRoles.GUARDIAN, true);
        _add(inst, m, IFloatingMarket.writeOff.selector, "writeOff()", CapRoles.GUARDIAN, true);
        _add(inst, m, IFixedMarket.writeOff.selector, "writeOff(uint256)", CapRoles.GUARDIAN, true);
        _add(inst, m, IFixedMarket.extendAdmin.selector, "extendAdmin", CapRoles.KEEPER, true);
        _add(inst, m, IFloatingMarket.liquidate.selector, "liquidate(address,uint256)", CapRoles.LIQUIDATOR, true);
        _add(inst, m, IFixedMarket.liquidate.selector, "liquidate(uint256,address,uint256)", CapRoles.LIQUIDATOR, true);
        uint64 b = borrowerSet ? borrowerRole : CapRoles.ADMIN;
        _add(inst, m, IFloatingMarket.borrow.selector, "borrow(address,uint256)", b, borrowerSet);
        _add(inst, m, IFixedMarket.borrow.selector, "borrow(address,uint256,uint256)", b, borrowerSet);
        _add(inst, m, IFixedMarket.borrowMore.selector, "borrowMore", b, borrowerSet);
        // extend: _configureMarketRoles wires it to ownerRole, setBorrowerRole then rewires it to the borrower
        _add(inst, m, IFixedMarket.extend.selector, "extend", borrowerSet ? borrowerRole : ownerRole, true);
        _add(inst, m, IERC4626.deposit.selector, "deposit (dead selector on market)", CapRoles.ADMIN, false);
        _add(inst, m, IERC4626.mint.selector, "mint (dead selector on market)", CapRoles.ADMIN, false);
    }

    function _trancheRows(string memory inst, address t) internal {
        uint64 dep = _depositorRole(t);
        _add(inst, t, ITranche.setDepositorRole.selector, "setDepositorRole", ownerRole, true);
        _add(inst, t, ITranche.fund.selector, "fund", CapRoles.MARKET, true);
        _add(inst, t, IERC4626.deposit.selector, "deposit", dep, true);
        _add(inst, t, IERC4626.mint.selector, "mint", dep, true);
        _add(inst, t, ITranche.slash.selector, "slash (NOT restricted; msg.sender==market)", CapRoles.ADMIN, false);
    }

    function _underwriterRows(string memory inst, address u, bool configured) internal {
        _add(inst, u, IUnderwriter.addTranche.selector, "addTranche", curatorRole, true);
        _add(inst, u, IUnderwriter.removeTranche.selector, "removeTranche", curatorRole, true);
        _add(inst, u, IUnderwriter.setDepositorRole.selector, "setDepositorRole", curatorRole, true);
        _add(inst, u, IUnderwriter.setAllocatorRole.selector, "setAllocatorRole", curatorRole, true);
        _add(inst, u, IUnderwriter.report.selector, "report", CapRoles.KEEPER, true);
        uint64 a = configured ? _allocatorRole(u) : CapRoles.ADMIN;
        uint64 d = configured ? _depositorRole(u) : CapRoles.ADMIN;
        _add(inst, u, IUnderwriter.allocate.selector, "allocate", a, configured);
        _add(inst, u, IUnderwriter.deallocate.selector, "deallocate", a, configured);
        _add(inst, u, IUnderwriter.deallocateAsync.selector, "deallocateAsync", a, configured);
        _add(inst, u, IUnderwriter.finalizeDeallocateAsync.selector, "finalizeDeallocateAsync", a, configured);
        _add(inst, u, IUnderwriter.setDefaultTranche.selector, "setDefaultTranche", a, configured);
        _add(inst, u, IERC4626.deposit.selector, "deposit", d, configured);
        _add(inst, u, IERC4626.mint.selector, "mint", d, configured);
    }

    function _roleName(uint64 r) internal view returns (string memory) {
        if (r == 0) return "ADMIN(0)";
        if (r == 1) return "GUARDIAN(1)";
        if (r == 2) return "GOVERNOR(2)";
        if (r == 3) return "KEEPER(3)";
        if (r == 4) return "MARKET(4)";
        if (r == 5) return "REGISTRY(5)";
        if (r == 6) return "LIQUIDATOR(6)";
        if (r == 7) return "WHITELISTED(7)";
        if (r == 8) return "PROTOCOL(8)";
        if (r == PUBLIC_ROLE) return "PUBLIC";
        if (r == ownerRole) return string.concat("ownerRole(", vm.toString(r), ")");
        if (r == borrowerRole) return string.concat("borrowerRole(", vm.toString(r), ")");
        if (r == curatorRole) return string.concat("curatorRole(", vm.toString(r), ")");
        if (r == allocatorRole) return string.concat("allocatorRole(", vm.toString(r), ")");
        return string.concat("operator/depositor(", vm.toString(r), ")");
    }

    /// Prints the live table. Always passes.
    function test_printRoleTable() public view {
        console.log("| instance | target | selector | function | live role | intended | note |");
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            uint64 live = accessManager.getTargetFunctionRole(r.target, r.selector);
            string memory note = "";
            if (live == 0 && !r.explicitlyWired) note = "ADMIN by omission (never wired)";
            else if (live == 0) note = "ADMIN explicit";
            else if (live != r.expected) note = "MISMATCH vs _configure*";
            console.log(
                string.concat(
                    "| ",
                    r.instance,
                    " | ",
                    vm.toString(r.target),
                    " | ",
                    vm.toString(abi.encodePacked(r.selector)),
                    " | ",
                    r.fn,
                    " | ",
                    _roleName(live),
                    " | ",
                    _roleName(r.expected),
                    " | ",
                    note,
                    " |"
                )
            );
        }
    }

    /// Every restricted selector must match the role its _configure* names.
    function test_liveMatchesIntent() public view {
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            assertEq(accessManager.getTargetFunctionRole(r.target, r.selector), r.expected, r.fn);
        }
    }

    /// I40 strict form: no `restricted` selector resolves to ADMIN by omission. Expected to FAIL:
    /// upgradeToAndCall on the 7 UUPS proxies, borrow* on a market before setBorrowerRole,
    /// allocate*/deposit/mint on an underwriter before set*Role are all 0 by omission.
    function test_I40_noRestrictedSelectorResolvesToAdminByOmission() public view {
        uint256 omissions;
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            // only `restricted` selectors count; skip the rows we tagged NOT restricted / dead
            if (_isUnrestrictedRow(r.fn)) continue;
            uint64 live = accessManager.getTargetFunctionRole(r.target, r.selector);
            if (live == 0 && !r.explicitlyWired) {
                omissions++;
                console.log(string.concat("ADMIN by omission: ", r.instance, ".", r.fn));
            }
        }
        assertEq(omissions, 0, "restricted selectors resolving to ADMIN(0) without explicit wiring");
    }

    function _isUnrestrictedRow(string memory fn) internal pure returns (bool) {
        bytes memory b = bytes(fn);
        // crude: rows that mention NOT restricted / dead selector are not `restricted`
        return _contains(b, "NOT restricted") || _contains(b, "dead selector");
    }

    function _contains(bytes memory hay, string memory needleS) internal pure returns (bool) {
        bytes memory needle = bytes(needleS);
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// Negative checks RoleTable.t.sol never makes: a stranger, a GOVERNOR-only, a KEEPER-only
    /// account cannot call upgradeToAndCall on any UUPS proxy; only ADMIN can.
    function test_upgradeToAndCall_isAdminOnly_onAllSevenProxies() public {
        address[7] memory proxies = [
            address(registry),
            address(stablecoin),
            address(irm),
            address(oracle),
            address(vault),
            wrapper,
            address(beaconFactory)
        ];
        address gov = makeAddr("govOnly");
        accessManager.grantRole(CapRoles.GOVERNOR, gov, 0);
        accessManager.grantRole(CapRoles.GUARDIAN, gov, 0);
        accessManager.grantRole(CapRoles.KEEPER, gov, 0);
        for (uint256 i; i < proxies.length; ++i) {
            vm.prank(gov);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, gov));
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(address(0xdead), "");
        }
    }
}
