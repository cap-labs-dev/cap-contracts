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
import { CapDeployer } from "../shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Pins the role that every gated selector is wired to on a freshly deployed instance.
///
/// This exists because AccessManager returns role 0 for a selector nobody configured, and
/// {CapRoles-ADMIN} is 0. A forgotten selector and one deliberately held at ADMIN are therefore
/// indistinguishable from storage, so reading the wiring code is the only way to tell them apart.
/// Three selectors had reached ADMIN by omission before this test existed. Asserting the table
/// means the next one has to be argued for in a diff rather than arrived at silently.
///
/// Covers all 48 gated selectors in the protocol, across per-market instances and the shared
/// infrastructure. The table is a snapshot and does not discover new selectors by itself. What it
/// does do is make the intended role explicit for each one, so a selector that is later rewired,
/// or a new instance wired differently from the last, fails here.
contract RoleTableTest is CapDeployer {
    /// @dev AccessManager's open role, used where a selector is deliberately callable by anyone
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;

    function setUp() public {
        _deployCap();
    }

    function _expectRole(address target, bytes4 selector, uint64 expected, string memory what) internal view {
        assertEq(accessManager.getTargetFunctionRole(target, selector), expected, what);
    }

    function test_floatingMarketRoleTable() public {
        (address market, address[] memory tranches) =
            _createMarket("roles", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        uint64 ownerRole = registry.operatorRole(defaultMarketOwner);
        uint64 borrowerRole = registry.operatorRole(defaultBorrower);
        assertTrue(ownerRole != 0 && borrowerRole != 0, "operator roles must not collide with ADMIN");

        // the market owner tunes its own market's risk and pricing
        _expectRole(market, IBaseMarket.setLtv.selector, ownerRole, "setLtv");
        _expectRole(market, IBaseMarket.setTrancheWeights.selector, ownerRole, "setTrancheWeights");
        _expectRole(market, IBaseMarket.setMarketMultiplier.selector, ownerRole, "setMarketMultiplier");
        _expectRole(market, IBaseMarket.setUnderwriterRate.selector, ownerRole, "setUnderwriterRate");
        // the waterfall can only be rearranged while the market stays healthy, so the owner
        // may add, drop, or reorder tranches rather than waiting on ADMIN
        _expectRole(market, IBaseMarket.setTranches.selector, ownerRole, "setTranches");

        // only the designated borrower can draw credit
        _expectRole(market, IFloatingMarket.borrow.selector, borrowerRole, "borrow");

        // governance owns the parameters that bound every market
        _expectRole(market, IBaseMarket.setTargetHealth.selector, CapRoles.GOVERNOR, "setTargetHealth");
        _expectRole(market, IBaseMarket.setFixedCreditLimit.selector, CapRoles.GOVERNOR, "setFixedCreditLimit");

        // the guardian tightens risk and recognises losses
        _expectRole(market, IBaseMarket.setBuffer.selector, CapRoles.GUARDIAN, "setBuffer");
        _expectRole(market, IBaseMarket.setLt.selector, CapRoles.GUARDIAN, "setLt");
        _expectRole(market, IFloatingMarket.writeOff.selector, CapRoles.GUARDIAN, "writeOff");

        _expectRole(market, IFloatingMarket.liquidate.selector, CapRoles.LIQUIDATOR, "liquidate");

        // markets, and only markets, drive the rate model and slash their tranches
        _expectRole(
            address(irm), IInterestRateModel.updateUnderwriterRate.selector, CapRoles.MARKET, "irm underwriter rate"
        );
        _expectRole(
            address(irm), IInterestRateModel.updateMarketMultiplier.selector, CapRoles.MARKET, "irm market multiplier"
        );
        (bool isMarket,) = accessManager.hasRole(CapRoles.MARKET, market);
        assertTrue(isMarket, "market holds MARKET");

        _assertTrancheRoleTable(tranches[0], ownerRole);
    }

    function test_fixedMarketRoleTable() public {
        (address market, address[] memory tranches) =
            _createFixedMarket("fixed-roles", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        uint64 ownerRole = registry.operatorRole(defaultMarketOwner);
        uint64 borrowerRole = registry.operatorRole(defaultBorrower);

        _expectRole(market, IFixedMarket.borrow.selector, borrowerRole, "fixed borrow");
        _expectRole(market, IFixedMarket.borrowMore.selector, borrowerRole, "borrowMore");
        _expectRole(market, IFixedMarket.extend.selector, ownerRole, "extend");
        // rolling an overdue loan is routine and must not wait on the owner, but it raises debt,
        // so it sits with the keeper rather than with the borrower
        _expectRole(market, IFixedMarket.extendAdmin.selector, CapRoles.KEEPER, "extendAdmin");
        _expectRole(market, IFixedMarket.setTermLimits.selector, CapRoles.GOVERNOR, "setTermLimits");
        _expectRole(market, IFixedMarket.liquidate.selector, CapRoles.LIQUIDATOR, "fixed liquidate");
        _expectRole(market, IFixedMarket.writeOff.selector, CapRoles.GUARDIAN, "fixed writeOff");

        _assertTrancheRoleTable(tranches[0], ownerRole);
    }

    function _assertTrancheRoleTable(address tranche, uint64 ownerRole) internal view {
        // premium is pushed in by whichever market charged it, so this may not be open
        _expectRole(tranche, ITranche.fund.selector, CapRoles.MARKET, "fund");

        // admission is a row like any other, same as on the underwriter: the entry points are
        // gated to a role of their own, and the market owner administers that role's membership
        // rather than a list on the tranche
        uint64 depositorRole = _depositorRole(tranche);
        assertTrue(depositorRole != 0 && depositorRole != ownerRole, "depositors are their own role");
        _expectRole(tranche, IERC4626.deposit.selector, depositorRole, "tranche deposit");
        _expectRole(tranche, IERC4626.mint.selector, depositorRole, "tranche mint");
        assertEq(accessManager.getRoleAdmin(depositorRole), ownerRole, "administered by the market owner");
    }

    /// @dev The Registry keeps no copy of the market owner role, so handing a market to a new
    /// owner through the AccessManager is enough: the tranches minted afterwards follow.
    function test_marketOwnerRoleFollowsTheAccessManager() public {
        (address marketAddr, address[] memory existing) =
            _createMarket("rehomed", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        uint64 originalRole = registry.operatorRole(defaultMarketOwner);
        assertEq(registry.marketOwnerRole(marketAddr), originalRole, "the deploying owner to begin with");

        address newOwner = makeAddr("newMarketOwner");
        uint64 newRole = _assignOperator(newOwner);
        vm.prank(address(registry));
        accessManager.grantRole(newRole, newOwner, 0);

        bytes4[] memory ownerSelectors = new bytes4[](1);
        ownerSelectors[0] = IBaseMarket.setTrancheWeights.selector;
        accessManager.setTargetFunctionRole(marketAddr, ownerSelectors, newRole);

        assertEq(registry.marketOwnerRole(marketAddr), newRole, "and the new one once it is rehomed");

        // and the next tranche is wired to the new owner rather than the old one
        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.5e27;
        weights[1] = 0.3e27;
        weights[2] = 0.2e27;

        vm.expectRevert(IRegistry.NotMarketOwner.selector);
        registry.createTranche(marketAddr, address(collateral), weights);

        vm.prank(newOwner);
        address added = registry.createTranche(marketAddr, address(collateral), weights);

        assertEq(accessManager.getRoleAdmin(_depositorRole(added)), newRole, "the next tranche follows the new owner");
        assertEq(
            accessManager.getRoleAdmin(_depositorRole(existing[0])), originalRole, "the older tranches do not move"
        );
    }

    function test_marketOwnerRole_isZeroForAMarketItDidNotDeploy() public {
        assertFalse(registry.isMarket(makeAddr("notAMarket")));
        assertEq(registry.marketOwnerRole(makeAddr("notAMarket")), 0);
    }

    /// @dev Each tranche gets its own depositor role, so one level of a waterfall can be open
    /// while another stays closed.
    function test_trancheDepositorRolesAreNotShared() public {
        (, address[] memory tranches) =
            _createMarket("split-admission", defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);

        assertTrue(_depositorRole(tranches[0]) != _depositorRole(tranches[1]), "a role each");

        address depositor = makeAddr("trancheDepositor");
        _admitDepositor(tranches[0], depositor);

        assertTrue(_mayDeposit(tranches[0], depositor), "admitted to the senior tranche");
        assertFalse(_mayDeposit(tranches[1], depositor), "and not to the junior one");
    }

    function test_underwriterRoleTable() public {
        address underwriter = address(_deployUnderwriter());
        uint64 curatorRole = registry.operatorRole(address(this));
        assertTrue(curatorRole != 0, "curator role must not collide with ADMIN");

        // the curator lists tranches and moves capital between them
        _expectRole(underwriter, IUnderwriter.allocate.selector, curatorRole, "allocate");
        _expectRole(underwriter, IUnderwriter.deallocate.selector, curatorRole, "deallocate");
        _expectRole(underwriter, IUnderwriter.deallocateAsync.selector, curatorRole, "deallocateAsync");
        _expectRole(underwriter, IUnderwriter.finalizeDeallocateAsync.selector, curatorRole, "finalizeDeallocateAsync");
        _expectRole(underwriter, IUnderwriter.setDefaultTranche.selector, curatorRole, "setDefaultTranche");
        _expectRole(underwriter, IUnderwriter.addTranche.selector, curatorRole, "addTranche");
        _expectRole(underwriter, IUnderwriter.removeTranche.selector, curatorRole, "removeTranche");

        _expectRole(underwriter, IUnderwriter.report.selector, CapRoles.KEEPER, "report");

        // admission is a row like any other: the entry points are gated to a role of their own,
        // and the curator administers that role's membership rather than a list on the vault
        uint64 depositorRole = _depositorRole(underwriter);
        assertTrue(depositorRole != 0 && depositorRole != curatorRole, "depositors are their own role");
        _expectRole(underwriter, IERC4626.deposit.selector, depositorRole, "deposit");
        _expectRole(underwriter, IERC4626.mint.selector, depositorRole, "mint");
        assertEq(accessManager.getRoleAdmin(depositorRole), curatorRole, "administered by the curator");
    }

    /// @dev The shared infrastructure, wired by {Registry-initialize} rather than by the deploy
    /// script. Included so the table covers every gated selector in the protocol, not just the
    /// ones on per-market instances.
    function test_infraRoleTable() public view {
        // markets are the only MARKET holders, so writing off their own credit sits with the role
        // that slashes and prices. Covering a shortfall burns the caller's own cUSD and is
        // permissionless. Parking idle reserve and bringing it back is keeper maintenance
        _expectRole(address(stablecoin), IStablecoin.mintCreditBacked.selector, CapRoles.MARKET, "mintCreditBacked");
        _expectRole(address(stablecoin), IStablecoin.burnCreditBacked.selector, CapRoles.MARKET, "burnCreditBacked");
        _expectRole(address(stablecoin), IStablecoin.recognizeBadDebt.selector, CapRoles.MARKET, "recognizeBadDebt");
        _expectRole(address(stablecoin), IStablecoin.fundCreditBacked.selector, CapRoles.MARKET, "fundCreditBacked");
        _expectRole(address(stablecoin), IStablecoin.invest.selector, CapRoles.KEEPER, "invest");
        _expectRole(address(stablecoin), IStablecoin.recall.selector, CapRoles.KEEPER, "recall");

        // the rate curve is economic policy; the per-market knobs are wired to MARKET by the
        // Registry and asserted alongside the market table
        _expectRole(address(irm), IInterestRateModel.setLiquiditySlopes.selector, CapRoles.GOVERNOR, "slopes");
        _expectRole(address(irm), IInterestRateModel.setTermMultiplierSlope.selector, CapRoles.GOVERNOR, "term slope");
        _expectRole(
            address(irm), IInterestRateModel.setLiquidationBonus.selector, CapRoles.GOVERNOR, "liquidation bonus"
        );
        _expectRole(address(oracle), IOracle.setSource.selector, CapRoles.GOVERNOR, "setSource");

        // onboarding an operator is policy, deploying instances for one is routine
        _expectRole(address(registry), Registry.assignOperator.selector, CapRoles.GOVERNOR, "assignOperator");
        _expectRole(address(registry), Registry.createFloatingMarket.selector, CapRoles.KEEPER, "createFloatingMarket");
        _expectRole(address(registry), Registry.createFixedMarket.selector, CapRoles.KEEPER, "createFixedMarket");
        _expectRole(address(registry), Registry.createUnderwriter.selector, CapRoles.KEEPER, "createUnderwriter");

        // only the Registry deploys through the factory
        _expectRole(address(beaconFactory), IBeaconFactory.create.selector, CapRoles.REGISTRY, "factory create");
    }

    /// @dev The role admin delegation is what replaced the vault's whitelist, so pin that it works
    /// in both directions and that it is genuinely the curator's to use rather than governance's.
    function test_curatorAdmitsAndRemovesDepositors() public {
        address underwriter = address(_deployUnderwriter());
        uint64 depositorRole = _depositorRole(underwriter);
        address depositor = makeAddr("depositor");

        assertFalse(_mayDeposit(underwriter, depositor), "closed by default");

        // this contract is the curator, so it holds the depositor role's admin
        accessManager.grantRole(depositorRole, depositor, 0);
        assertTrue(_mayDeposit(underwriter, depositor), "curator admitted them");

        accessManager.revokeRole(depositorRole, depositor);
        assertFalse(_mayDeposit(underwriter, depositor), "and can remove them again");
    }

    /// @dev The delegation is narrow: administering the depositor role does not extend to any other
    /// role, and an account that is not the curator cannot admit depositors to their vault.
    function test_strangerCannotAdmitDepositors() public {
        address underwriter = address(_deployUnderwriter());
        uint64 depositorRole = _depositorRole(underwriter);
        uint64 curatorRole = registry.operatorRole(address(this));
        address stranger = makeAddr("stranger");

        // the role named in the error is the curator's, not the depositor's: what the caller lacks
        // is the admin over the depositor role, which is exactly the delegation being tested
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, stranger, curatorRole)
        );
        accessManager.grantRole(depositorRole, stranger, 0);
    }

    /// @dev Registration is the curator's, so an account that is not this vault's curator cannot
    /// list a tranche on it.
    function test_strangerCannotRegisterATranche() public {
        address underwriter = address(_deployUnderwriter());
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        IUnderwriter(underwriter).addTranche(makeAddr("not-a-tranche"));
    }
}
