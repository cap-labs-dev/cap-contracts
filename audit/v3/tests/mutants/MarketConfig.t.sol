// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { IRegistry } from "../../../../contracts/interfaces/IRegistry.sol";
import { CapRoles } from "../../../../contracts/utils/CapRoles.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice Killing tests for market configuration and owner-access survivors.
///
/// - Gambit `BaseMarket#10` deletes `$.buffer = IRegistry(_registry).buffer()` in
///   {BaseMarket-__BaseMarket_init} and `Registry#25` deletes `targetHealth = init.targetHealth` in
///   {Registry-initialize}. Both survive because `CapDeployer._applyMarketDefaults` re-sets
///   buffer, lt and targetHealth on every market the suite creates, so the inherited values are
///   never observed. A market created straight from the Registry would run with `buffer == 0`
///   (requirement `debt / lt` instead of `debt / (lt - buffer)`: 12.5 % less collateral locked
///   at the defaults) or `targetHealth == 0`.
/// - Hand mutant H24 drops the `lt <= 1e27` bound in {BaseMarket-setLt}; the bound is only tested
///   on `Registry.initialize`. Above one ray the market lends against more than its collateral.
/// - Gambit `Registry#211` replaces `IBaseMarket.setBorrowerRole.selector` with `0` in
///   {Registry-_configureMarketRoles}, so the selector falls back to the AccessManager default
///   (ADMIN). It survives because `defaultMarketOwner == address(this)` holds ADMIN (§1.7), and
///   `RoleTable.t.sol:58` checks only `setDepositorRole` on the market.
/// - Hand mutant H16 drops `isOperatorRole` in {Registry-setBorrowerRole}: a market owner could
///   name a protocol role (GUARDIAN, ADMIN, ...) as its borrower role. `Registry#79` drops the
///   PUBLIC_ROLE check on the same path.
contract MarketConfigKillTest is CapDeployer {
    address internal owner = makeAddr("independentOwner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployCap();
    }

    /// @dev A market whose owner role is held by `owner` alone. `CapDeployer._createMarket` cannot
    /// be used here: its `_applyMarketDefaults` calls owner-role setters from the test contract,
    /// and ADMIN does not bypass a target role in AccessManager.
    function _ownedMarket(string memory name) internal returns (address marketAddr, uint64 ownerRole) {
        ownerRole = _assignOperator(owner);
        (marketAddr,) =
            registry.createFloatingMarket(_uniformAssets(2), capConfig.defaultTrancheWeights, name, ownerRole);
    }

    /// Kills BaseMarket#10 and Registry#25: a market created from the Registry, with no setter
    /// called afterwards, carries the Registry's lt, buffer and targetHealth.
    function test_freshMarketInheritsTheRegistryRiskParameters() public {
        assertEq(registry.lt(), capConfig.defaultLt, "registry lt");
        assertEq(registry.buffer(), capConfig.defaultBuffer, "registry buffer");
        assertEq(registry.targetHealth(), capConfig.defaultTargetHealth, "registry targetHealth is stored");

        (address marketAddr,) = registry.createFloatingMarket(
            _uniformAssets(2), capConfig.defaultTrancheWeights, "raw", _operatorRoleOf(defaultMarketOwner)
        );
        FloatingMarket market = FloatingMarket(marketAddr);

        assertEq(market.lt(), capConfig.defaultLt, "lt inherited");
        assertEq(market.buffer(), capConfig.defaultBuffer, "buffer inherited");
        assertEq(market.targetHealth(), capConfig.defaultTargetHealth, "targetHealth inherited");
        assertGt(market.buffer(), 0, "the buffer is not silently zero");
        assertGe(market.targetHealth(), 1.25e27, "the target is not silently zero");
    }

    /// Kills H24: the liquidation threshold cannot exceed one ray.
    function test_ltIsBoundedByOneRay() public {
        MarketBundle memory b = _createReadyMarket("bound");

        vm.expectRevert(IBaseMarket.InvalidLt.selector);
        b.market.setLt(1e27 + 1);

        b.market.setLt(1e27);
        assertEq(b.market.lt(), 1e27, "exactly one ray is the ceiling");
    }

    /// Kills Registry#211: the market owner, holding nothing but its operator role, can set the
    /// borrower role; a stranger cannot; and the selector is wired to the owner role, not ADMIN.
    function test_marketOwnerAloneCanSetTheBorrowerRole() public {
        (address marketAddr, uint64 ownerRole) = _ownedMarket("owned");
        uint64 borrowerRole = _operatorRoleOf(defaultBorrower);
        (bool isAdmin,) = accessManager.hasRole(CapRoles.ADMIN, owner);
        assertFalse(isAdmin, "the owner is not an admin");

        assertEq(
            accessManager.getTargetFunctionRole(marketAddr, IBaseMarket.setBorrowerRole.selector),
            ownerRole,
            "setBorrowerRole is wired to the owner role"
        );

        vm.prank(owner);
        IBaseMarket(marketAddr).setBorrowerRole(borrowerRole);
        assertEq(
            accessManager.getTargetFunctionRole(marketAddr, FloatingMarket.borrow.selector),
            borrowerRole,
            "and the owner's call re-wires borrow"
        );

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        IBaseMarket(marketAddr).setBorrowerRole(borrowerRole);
    }

    /// Kills H16 and Registry#79: the borrower role must be an operator role, never a protocol
    /// role and never the public role.
    function test_borrowerRoleMustBeAnOperatorRole() public {
        (address marketAddr,) = _ownedMarket("gated");
        vm.prank(owner);
        IBaseMarket(marketAddr).setBorrowerRole(_operatorRoleOf(defaultBorrower));

        vm.prank(owner);
        vm.expectRevert(IRegistry.NotOperatorRole.selector);
        IBaseMarket(marketAddr).setBorrowerRole(CapRoles.GUARDIAN);

        vm.prank(owner);
        vm.expectRevert(IRegistry.NotOperatorRole.selector);
        IBaseMarket(marketAddr).setBorrowerRole(CapRoles.ADMIN);

        vm.prank(owner);
        vm.expectRevert(IRegistry.PublicRole.selector);
        IBaseMarket(marketAddr).setBorrowerRole(type(uint64).max);

        assertEq(
            accessManager.getTargetFunctionRole(marketAddr, FloatingMarket.borrow.selector),
            _operatorRoleOf(defaultBorrower),
            "borrow stays wired to the borrower's operator role"
        );
    }
}
