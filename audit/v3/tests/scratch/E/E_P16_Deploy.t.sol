// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// WS-E / P16: deploy wiring, upgrade authority, privileged fund-movement paths, initializers.

import { BeaconFactory } from "../../../../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../../../contracts/cap/Vault.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { Oracle } from "../../../../../contracts/cap/oracle/Oracle.sol";
import { IAeraVault } from "../../../../../contracts/interfaces/IAeraVault.sol";
import { IRegistry } from "../../../../../contracts/interfaces/IRegistry.sol";
import { CapRoles } from "../../../../../contracts/utils/CapRoles.sol";
import { Users } from "../../../../../script/config/Users.sol";
import {
    ImplementationsConfig,
    InfraConfig,
    UsersConfig
} from "../../../../../script/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../../../../script/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../../../../script/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../../../../script/deploy/service/DeployInfra.sol";
import { MockAeraVault } from "../../../../../test/shared/mocks/MockAeraVault.sol";
import { MockCreateX } from "../../../../../test/shared/mocks/MockCreateX.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

/// Malicious Registry implementation: once it is behind the Registry proxy it inherits the
/// proxy's ADMIN membership on the AccessManager and can hand ADMIN to anyone.
contract EvilRegistry is UUPSUpgradeable {
    function takeover(address manager, address who) external {
        IAccessManager(manager).grantRole(0, who, 0);
    }
    function _authorizeUpgrade(address) internal override { }
}

/// "Reserve vault" that keeps whatever it is allowed to pull.
contract Thief is IAeraVault {
    function deposit(TokenAmount[] calldata a) external {
        for (uint256 i; i < a.length; ++i) {
            a[i].token.transferFrom(msg.sender, address(this), a[i].amount);
        }
    }

    function withdraw(TokenAmount[] calldata) external pure {
        revert("gone");
    }
}

contract E_P16_Deploy is Test, Users, DeployImplems, DeployInfra, ConfigureAccessControl {
    UsersConfig internal users;
    InfraConfig internal infra;
    ImplementationsConfig internal implems;
    address internal deployer = address(this);
    address internal admin = makeAddr("admin");
    address internal governor = makeAddr("governor");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        vm.etch(address(CREATEX), address(new MockCreateX()).code);
        users = UsersConfig({
            deployer: deployer,
            governor: governor,
            keeper: keeper,
            guardian: guardian,
            admin: admin,
            liquidator: liquidator,
            stablecoinUnderlying: address(new MockERC20("USD Coin", "USDC", 18)),
            reserveVault: address(new MockAeraVault())
        });
        MockERC20(users.stablecoinUnderlying).mint(address(this), 2e18);
        implems = _deployImplementations();
        infra = _deployInfra(implems, users);
        _initInfraAccessControl(infra, users);
    }

    // external shim so msg.sender inside _users() is a prankable EOA
    function usersFromEnv() external view returns (UsersConfig memory) {
        return _users();
    }

    /// script/config/Users.sol with no role env vars: every role falls back to the broadcast wallet.
    function test_defaultDeploy_everyRoleOnOneEOA() public {
        address wallet = makeAddr("broadcastWallet");
        vm.setEnv("STABLECOIN_UNDERLYING", vm.toString(users.stablecoinUnderlying));
        vm.prank(wallet);
        UsersConfig memory u = this.usersFromEnv();
        console.log("deployer  ", u.deployer);
        console.log("admin     ", u.admin);
        console.log("governor  ", u.governor);
        console.log("keeper    ", u.keeper);
        console.log("guardian  ", u.guardian);
        console.log("liquidator", u.liquidator);
        console.log("reserveVault", u.reserveVault);
        assertEq(u.admin, wallet);
        assertEq(u.governor, wallet);
        assertEq(u.keeper, wallet);
        assertEq(u.guardian, wallet);
        assertEq(u.liquidator, wallet);
        assertEq(u.reserveVault, address(0));
    }

    /// Who holds what after the deploy services run (distinct addresses per role here).
    function test_postDeploy_roleHolders() public view {
        IAccessManager m = IAccessManager(infra.accessManager);
        (bool a,) = m.hasRole(CapRoles.ADMIN, infra.registry);
        assertTrue(a, "Registry holds ADMIN permanently");
        (bool r,) = m.hasRole(CapRoles.REGISTRY, infra.registry);
        assertTrue(r);
        (bool a2,) = m.hasRole(CapRoles.ADMIN, admin);
        assertTrue(a2);
        (bool d,) = m.hasRole(CapRoles.ADMIN, deployer);
        assertFalse(d, "deployer dropped ADMIN");
        (bool g,) = m.hasRole(CapRoles.GOVERNOR, governor);
        assertTrue(g);
        (bool k,) = m.hasRole(CapRoles.KEEPER, keeper);
        assertTrue(k);
        (bool gu,) = m.hasRole(CapRoles.GUARDIAN, guardian);
        assertTrue(gu);
        (bool l,) = m.hasRole(CapRoles.LIQUIDATOR, liquidator);
        assertTrue(l);
        // nobody is WHITELISTED; no grant delays; no admin delays on any target
        assertEq(m.getRoleGrantDelay(CapRoles.ADMIN), 0);
        assertEq(m.getTargetAdminDelay(infra.registry), 0);
        assertEq(m.getTargetAdminDelay(infra.stablecoin), 0);
        assertEq(m.getRoleAdmin(CapRoles.GOVERNOR), CapRoles.ADMIN);
        assertEq(m.getRoleGuardian(CapRoles.GOVERNOR), CapRoles.ADMIN);
    }

    /// Registry.upgradeToAndCall resolves to role 0 by omission (never wired) => ADMIN, no delay.
    /// An ADMIN upgrade of the Registry is a full takeover: the new code inherits the proxy's
    /// ADMIN membership and can grant ADMIN to anyone in the same tx.
    function test_registryUpgrade_isAdminByOmission_andIsFullTakeover() public {
        IAccessManager m = IAccessManager(infra.accessManager);
        assertEq(
            m.getTargetFunctionRole(infra.registry, UUPSUpgradeable.upgradeToAndCall.selector),
            0,
            "never wired -> ADMIN"
        );

        address attacker = makeAddr("attacker");
        EvilRegistry evil = new EvilRegistry();
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governor));
        UUPSUpgradeable(infra.registry).upgradeToAndCall(address(evil), "");

        vm.prank(admin);
        UUPSUpgradeable(infra.registry)
            .upgradeToAndCall(address(evil), abi.encodeCall(EvilRegistry.takeover, (infra.accessManager, attacker)));
        (bool isAdmin,) = m.hasRole(CapRoles.ADMIN, attacker);
        assertTrue(isAdmin, "arbitrary address now ADMIN via Registry upgrade");
    }

    /// Beacons: owned by the manager; upgradeTo reachable only through execute by ADMIN.
    function test_beaconUpgrade_onlyAdminViaExecute() public {
        bytes memory data = abi.encodeWithSignature("upgradeTo(address)", address(new Tranche()));
        vm.prank(governor);
        vm.expectRevert();
        IAccessManager(infra.accessManager).execute(infra.trancheBeacon, data);
        vm.prank(admin);
        IAccessManager(infra.accessManager).execute(infra.trancheBeacon, data);
    }

    /// GOVERNOR setReserveVault(thief) + KEEPER invest(all): the reserve leaves with no
    /// accounting update - totalAssets still reports par, unlockedSupply drops to 0.
    function test_governorPlusKeeper_moveReserveWithoutAccounting() public {
        Stablecoin sc = Stablecoin(infra.stablecoin);
        MockERC20 u = MockERC20(users.stablecoinUnderlying);
        address holder = makeAddr("holder");
        u.mint(holder, 1_000e18);
        vm.startPrank(holder);
        u.approve(address(sc), 1_000e18);
        sc.deposit(1_000e18, holder);
        vm.stopPrank();

        Thief thief = new Thief();
        vm.prank(governor);
        sc.setReserveVault(address(thief));
        uint256 onHand = u.balanceOf(address(sc));
        vm.prank(keeper);
        sc.invest(onHand);

        assertEq(u.balanceOf(address(sc)), 0);
        assertEq(u.balanceOf(address(thief)), onHand);
        assertEq(sc.totalAssets(), sc.totalSupply(), "still reports fully backed");
        assertEq(sc.badDebt(), 0);
        assertEq(sc.unlockedSupply(), 0, "nothing redeemable");
        vm.prank(keeper);
        vm.expectRevert();
        sc.recall(onHand);
    }

    /// Every proxy and every implementation rejects a second initialize.
    function test_initializers_cannotRerun() public {
        bytes memory initErr = abi.encodeWithSelector(Initializable.InvalidInitialization.selector);
        address a = infra.accessManager;
        vm.expectRevert(initErr);
        Vault(infra.vault).initialize(a);
        vm.expectRevert(initErr);
        Oracle(infra.oracle).initialize(a);
        vm.expectRevert(initErr);
        InterestRateModel(infra.irm).initialize(a, address(1), 1e27, 2e27, 1e27, 0, 1 hours);
        vm.expectRevert(initErr);
        Stablecoin(infra.stablecoin).initialize(a, users.stablecoinUnderlying, "x", "x", infra.irm, address(0));
        vm.expectRevert(initErr);
        Wrapper(infra.wrapper).initialize(a, infra.stablecoin);
        vm.expectRevert(initErr);
        BeaconFactory(infra.factory).initialize(a);
        IRegistry.InitParams memory p;
        vm.expectRevert(initErr);
        Registry(infra.registry).initialize(a, p);
        // implementations are disabled in their constructors
        vm.expectRevert(initErr);
        Vault(implems.vault).initialize(a);
        vm.expectRevert(initErr);
        Oracle(implems.oracle).initialize(a);
        vm.expectRevert(initErr);
        InterestRateModel(implems.irm).initialize(a, address(1), 1e27, 2e27, 1e27, 0, 1 hours);
        vm.expectRevert(initErr);
        Stablecoin(implems.stablecoin).initialize(a, users.stablecoinUnderlying, "x", "x", infra.irm, address(0));
        vm.expectRevert(initErr);
        Wrapper(implems.wrapper).initialize(a, infra.stablecoin);
        vm.expectRevert(initErr);
        Registry(implems.registry).initialize(a, p);
        vm.expectRevert(initErr);
        Tranche(implems.tranche).initialize(a, a, a, "x", "x", a, a, a);
        vm.expectRevert(initErr);
        Underwriter(implems.underwriter).initialize(a, a, "x", "x", a, a, a);
        vm.expectRevert(initErr);
        FloatingMarket(implems.floatingMarket).initialize(a, a, "x");
        vm.expectRevert(initErr);
        FixedMarket(implems.fixedMarket).initialize(a, a, "x", 1, 0, 0);
    }
}
