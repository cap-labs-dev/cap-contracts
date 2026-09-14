// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
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
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../../test/shared/CapRoles.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// Round-3 re-check of round-1 L-7 (FIXED in round 2). Every `restricted` selector in
/// `contracts/cap/**` (grep at HEAD: 52 functions) is resolved on a Registry-wired deployment.
/// Wiring lives entirely in `Registry._configure*` (Registry.sol:351-511), so this IS the
/// production table. Expected role 0 (ADMIN): only the UUPS `upgradeToAndCall` on singletons and
/// the beacons' `upgradeTo`, which are deliberately ADMIN.
contract R1_L7_RoleTable is CapDeployer {
    address fm;
    address fx;
    address tr;
    address uw;

    function setUp() public {
        _deployCap();
        (fm, tr,) = _createMarket("F");
        (fx,,) = _createFixedMarket("X");
        uw = address(_deployUnderwriter());
    }

    function _role(address target, bytes4 sel) internal view returns (uint64) {
        return accessManager.getTargetFunctionRole(target, sel);
    }

    function _expect(address target, bytes4 sel, uint64 role, string memory label) internal {
        uint64 got = _role(target, sel);
        emit log_named_uint(label, got);
        assertEq(got, role, label);
    }

    function _expectOperator(address target, bytes4 sel, string memory label) internal {
        uint64 got = _role(target, sel);
        emit log_named_uint(label, got);
        assertGe(got, CapRoles.FIRST_OPERATOR_ROLE, label);
    }

    function test_L7_everyRestrictedSelectorResolvesToItsNamedRole() public {
        // singletons
        _expect(address(beaconFactory), IBeaconFactory.create.selector, CapRoles.REGISTRY, "BeaconFactory.create");
        _expect(
            address(irm), IInterestRateModel.setLiquiditySlopes.selector, CapRoles.GOVERNOR, "IRM.setLiquiditySlopes"
        );
        _expect(
            address(irm),
            IInterestRateModel.setTermMultiplierSlope.selector,
            CapRoles.GOVERNOR,
            "IRM.setTermMultiplierSlope"
        );
        _expect(
            address(irm), IInterestRateModel.setLiquidationBonus.selector, CapRoles.GOVERNOR, "IRM.setLiquidationBonus"
        );
        _expect(
            address(irm),
            IInterestRateModel.setAveragingPeriod.selector,
            CapRoles.GOVERNOR,
            "IRM.setAveragingPeriod (round-1 omission)"
        );
        _expect(
            address(irm),
            IInterestRateModel.updateUnderwriterRate.selector,
            CapRoles.MARKET,
            "IRM.updateUnderwriterRate"
        );
        _expect(address(oracle), IOracle.setSource.selector, CapRoles.GOVERNOR, "Oracle.setSource (round-1 omission)");
        _expect(
            address(registry), IRegistry.createChildRoles.selector, CapRoles.WHITELISTED, "Registry.createChildRoles"
        );
        _expect(
            address(registry),
            IRegistry.createFloatingMarket.selector,
            CapRoles.WHITELISTED,
            "Registry.createFloatingMarket"
        );
        _expect(
            address(registry), IRegistry.createFixedMarket.selector, CapRoles.WHITELISTED, "Registry.createFixedMarket"
        );
        _expect(
            address(registry), IRegistry.createUnderwriter.selector, CapRoles.WHITELISTED, "Registry.createUnderwriter"
        );
        _expect(address(registry), IRegistry.setDepositorRole.selector, CapRoles.PROTOCOL, "Registry.setDepositorRole");
        _expect(address(registry), IRegistry.setBorrowerRole.selector, CapRoles.PROTOCOL, "Registry.setBorrowerRole");
        _expect(address(registry), IRegistry.setAllocatorRole.selector, CapRoles.PROTOCOL, "Registry.setAllocatorRole");
        _expect(
            address(stablecoin), IStablecoin.mintCreditBacked.selector, CapRoles.MARKET, "Stablecoin.mintCreditBacked"
        );
        _expect(
            address(stablecoin), IStablecoin.burnCreditBacked.selector, CapRoles.MARKET, "Stablecoin.burnCreditBacked"
        );
        _expect(
            address(stablecoin), IStablecoin.fundCreditBacked.selector, CapRoles.MARKET, "Stablecoin.fundCreditBacked"
        );
        _expect(
            address(stablecoin),
            IStablecoin.recognizeBadDebtInCredit.selector,
            CapRoles.MARKET,
            "Stablecoin.recognizeBadDebtInCredit"
        );
        _expect(
            address(stablecoin),
            IStablecoin.recognizeBadDebtInReserve.selector,
            CapRoles.GUARDIAN,
            "Stablecoin.recognizeBadDebtInReserve"
        );
        _expect(address(stablecoin), IStablecoin.invest.selector, CapRoles.KEEPER, "Stablecoin.invest");
        _expect(address(stablecoin), IStablecoin.recall.selector, CapRoles.KEEPER, "Stablecoin.recall");
        _expect(
            address(stablecoin), IStablecoin.setReserveVault.selector, CapRoles.GOVERNOR, "Stablecoin.setReserveVault"
        );
        // markets (floating and fixed instances share the table)
        address[2] memory ms = [fm, fx];
        for (uint256 i; i < 2; ++i) {
            address m = ms[i];
            _expectOperator(m, IBaseMarket.setLtv.selector, "market.setLtv");
            _expectOperator(m, IBaseMarket.setTrancheWeights.selector, "market.setTrancheWeights");
            _expectOperator(m, IBaseMarket.setMarketMultiplier.selector, "market.setMarketMultiplier");
            _expectOperator(m, IBaseMarket.setUnderwriterRate.selector, "market.setUnderwriterRate");
            _expectOperator(m, IBaseMarket.setBorrowerRole.selector, "market.setBorrowerRole");
            _expectOperator(m, IBaseMarket.setDepositorRole.selector, "market.setDepositorRole");
            _expectOperator(m, IFixedMarket.extend.selector, "market.extend (owner)");
            _expectOperator(m, IFloatingMarket.borrow.selector, "market.borrow (borrower)");
            _expectOperator(m, IFixedMarket.borrow.selector, "market.borrow(fixed) (borrower)");
            _expectOperator(m, IFixedMarket.borrowMore.selector, "market.borrowMore (borrower)");
            _expect(m, IBaseMarket.setTranches.selector, CapRoles.REGISTRY, "market.setTranches");
            _expect(m, IBaseMarket.setTargetHealth.selector, CapRoles.GOVERNOR, "market.setTargetHealth");
            _expect(m, IBaseMarket.setFixedCreditLimit.selector, CapRoles.GOVERNOR, "market.setFixedCreditLimit");
            _expect(m, IFixedMarket.setTermLimits.selector, CapRoles.GOVERNOR, "market.setTermLimits");
            _expect(m, IBaseMarket.setBuffer.selector, CapRoles.GUARDIAN, "market.setBuffer");
            _expect(m, IBaseMarket.setLt.selector, CapRoles.GUARDIAN, "market.setLt");
            _expect(m, IFloatingMarket.writeOff.selector, CapRoles.GUARDIAN, "market.writeOff");
            _expect(m, IFixedMarket.writeOff.selector, CapRoles.GUARDIAN, "market.writeOff(id)");
            _expect(m, IFixedMarket.extendAdmin.selector, CapRoles.KEEPER, "market.extendAdmin");
            _expect(m, IFloatingMarket.liquidate.selector, CapRoles.LIQUIDATOR, "market.liquidate");
            _expect(m, IFixedMarket.liquidate.selector, CapRoles.LIQUIDATOR, "market.liquidate(id)");
        }
        // tranche
        _expectOperator(tr, ITranche.setDepositorRole.selector, "tranche.setDepositorRole (owner)");
        _expect(tr, ITranche.fund.selector, CapRoles.MARKET, "tranche.fund");
        _expectOperator(tr, IERC4626.deposit.selector, "tranche.deposit (depositor)");
        _expectOperator(tr, IERC4626.mint.selector, "tranche.mint (depositor)");
        // underwriter
        _expectOperator(uw, IUnderwriter.addTranche.selector, "uw.addTranche (curator)");
        _expectOperator(uw, IUnderwriter.removeTranche.selector, "uw.removeTranche (curator)");
        _expectOperator(uw, IUnderwriter.setDepositorRole.selector, "uw.setDepositorRole (curator)");
        _expectOperator(uw, IUnderwriter.setAllocatorRole.selector, "uw.setAllocatorRole (curator)");
        _expectOperator(uw, IUnderwriter.allocate.selector, "uw.allocate (allocator)");
        _expectOperator(uw, IUnderwriter.deallocate.selector, "uw.deallocate (allocator)");
        _expectOperator(uw, IUnderwriter.deallocateAsync.selector, "uw.deallocateAsync (allocator)");
        _expectOperator(uw, IUnderwriter.finalizeDeallocateAsync.selector, "uw.finalizeDeallocateAsync (allocator)");
        _expectOperator(uw, IUnderwriter.setDefaultTranche.selector, "uw.setDefaultTranche (allocator)");
        _expect(uw, IUnderwriter.report.selector, CapRoles.KEEPER, "uw.report");
        _expectOperator(uw, IERC4626.deposit.selector, "uw.deposit (depositor)");
        _expectOperator(uw, IERC4626.mint.selector, "uw.mint (depositor)");
    }

    /// Deliberate ADMIN(0) selectors: UUPS upgrades on singletons and the beacons' upgradeTo.
    function test_L7_upgradeSelectorsAreAdminByDesign() public {
        bytes4 up = UUPSUpgradeable.upgradeToAndCall.selector;
        address[7] memory singletons = [
            address(registry),
            address(stablecoin),
            address(irm),
            address(oracle),
            address(vault),
            address(beaconFactory),
            address(0)
        ];
        for (uint256 i; i < 6; ++i) {
            _expect(singletons[i], up, CapRoles.ADMIN, "singleton.upgradeToAndCall -> ADMIN");
        }
        _expect(floatingMarketBeacon, UpgradeableBeacon.upgradeTo.selector, CapRoles.ADMIN, "beacon.upgradeTo -> ADMIN");
        _expect(trancheBeacon, UpgradeableBeacon.upgradeTo.selector, CapRoles.ADMIN, "beacon.upgradeTo -> ADMIN");
    }
}
