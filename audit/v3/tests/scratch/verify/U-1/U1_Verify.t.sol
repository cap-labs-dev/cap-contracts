// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Phase-3 adversarial verification of U-1 / U-2 (offline, no RPC).
// Reuses the v1 creation bytecode the author extracted (audit/v3/tests/scratch/U/V1Artifacts.sol,
// v1 main @ 695c828, OZ 5.4.0) but everything else is independent.
//
// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/U-1 forge test --match-path 'audit/v3/tests/scratch/verify/U-1/*' -vv
//
// Attacks tried:
//  (c) v1 Initializable is namespaced (OZ 5.x) and sits in the same slot HEAD reads -> initialize() reverts.
//  (d) HEAD-only namespaces (cap.storage.Stablecoin / PremiumVesting / ERC7540*, openzeppelin.storage.AccessManaged,
//      openzeppelin.storage.ERC4626 on cUSD) are all zero on a live v1 proxy => no overlap, but also no data.
//  (b) "permanent" / "no path": the v1 timelock can upgrade to ANY implementation first. A ~40-line raw-slot
//      Migrator (not in HEAD) followed by the HEAD implementation yields a fully working Stablecoin/Wrapper,
//      still upgradeable. So the brick is conditional on a *bare* upgrade, not on HEAD as such.

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../../contracts/cap/Wrapper.sol";
import { IPremiumVesting } from "../../../../../../contracts/interfaces/IPremiumVesting.sol";
import { V1Artifacts } from "../../U/V1Artifacts.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

interface IV1AccessControl {
    function checkAccess(bytes4, address, address) external view returns (bool);
}

/// @dev Stand-in for the v1 AccessControl proxy (0x7731...): one admin holds every role.
contract MockV1AccessControl {
    address public immutable admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function checkAccess(bytes4, address, address caller) external view returns (bool) {
        return caller == admin;
    }
}

contract Usdc6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockIrm {
    uint256 public calls;

    function updateLiquidityRate() external {
        calls++;
    }
}

interface IV1CapToken {
    function initialize(string memory, string memory, address, address, address, address[] calldata, address) external;
}

interface IV1StakedCap {
    function initialize(address _accessControl, address _asset, uint256 _lockDuration) external;
}

/// @dev Intermediate implementation the v1 timelock can upgrade to BEFORE HEAD. Not part of HEAD.
///      Authorised exactly like v1 (cap.storage.Access -> checkAccess(bytes4(0))). Writes the namespaces
///      HEAD reads by raw slot; nothing else. Then the timelock upgrades to HEAD through HEAD's own
///      `restricted` gate, which now resolves to the AccessManager written here.
contract Migrator is UUPSUpgradeable {
    bytes32 constant SLOT_V1_ACCESS = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;
    bytes32 constant SLOT_ACCESS_MANAGED = 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00;
    bytes32 constant SLOT_ERC4626 = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
    bytes32 constant SLOT_PREMIUM_VESTING = 0xcd5f59be90fcb6cd1e07c030ed45d88d80c86b8efb27e0d1fc4732fdedcd1c00;

    error NotV1Admin();

    function _v1Auth() internal view {
        address ac;
        assembly { ac := sload(SLOT_V1_ACCESS) }
        if (!IV1AccessControl(ac).checkAccess(bytes4(0), address(this), msg.sender)) revert NotV1Admin();
    }

    function _authorizeUpgrade(address) internal view override {
        _v1Auth();
    }

    function stablecoinBase() public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256("cap.storage.Stablecoin")) - 1)) & ~bytes32(uint256(0xff));
    }

    function migrateStablecoin(address authority, address asset, uint8 assetDecimals, address irm, address reserveVault)
        external
    {
        _v1Auth();
        bytes32 base = stablecoinBase();
        bytes32 pv = SLOT_PREMIUM_VESTING;
        uint256 erc4626 = uint256(uint160(asset)) | (uint256(assetDecimals) << 160);
        uint256 own0 = uint256(assetDecimals) | (uint256(uint160(irm)) << 8); // uint8 underlyingDecimals | address irm
        assembly {
            sstore(SLOT_ACCESS_MANAGED, authority)
            sstore(SLOT_ERC4626, erc4626)
            sstore(add(pv, 1), timestamp()) // lastUpdate
            sstore(add(pv, 5), address()) // stablecoin
            sstore(base, own0)
            sstore(add(base, 3), reserveVault)
        }
    }

    function migrateWrapper(address authority, address premiumVesting) external {
        _v1Auth();
        assembly { sstore(SLOT_ACCESS_MANAGED, authority) }
        IPremiumVesting(premiumVesting).optIn();
    }
}

abstract contract U_VerifyBase is Test {
    bytes32 constant SLOT_ERC20 = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
    bytes32 constant SLOT_INIT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant SLOT_ERC4626 = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
    bytes32 constant SLOT_ACCESS_MANAGED = 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00;
    bytes32 constant SLOT_V1_ACCESS = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;
    bytes32 constant SLOT_PREMIUM_VESTING = 0xcd5f59be90fcb6cd1e07c030ed45d88d80c86b8efb27e0d1fc4732fdedcd1c00;
    bytes32 constant SLOT_ERC7540 = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    Usdc6 usdc;
    MockV1AccessControl v1ac;
    MockIrm irm;
    AccessManager manager;
    address cusd;
    address stcusd;
    address headStablecoin;
    address headWrapper;
    address migrator;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SUPPLY = 84_884_291e18;
    uint256 constant ON_HAND_USDC = 3_219e6;

    function _create(bytes memory creation) internal returns (address addr) {
        assembly { addr := create(0, add(creation, 0x20), mload(creation)) }
        require(addr != address(0), "create failed");
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function setUp() public virtual {
        vm.warp(1_789_000_000);
        usdc = new Usdc6();
        v1ac = new MockV1AccessControl(address(this));
        irm = new MockIrm();
        manager = new AccessManager(address(this));

        vm.etch(V1Artifacts.VAULTLOGIC_ADDR, _create(V1Artifacts.vault_logic()).code);
        vm.etch(V1Artifacts.MINTERLOGIC_ADDR, _create(V1Artifacts.minter_logic()).code);
        vm.etch(V1Artifacts.FRACTIONALRESERVELOGIC_ADDR, _create(V1Artifacts.fractional_reserve_logic()).code);
        address v1CapTokenImpl = _create(V1Artifacts.cap_token());
        address v1StakedCapImpl = _create(V1Artifacts.staked_cap());

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        cusd = address(
            new ERC1967Proxy(
                v1CapTokenImpl,
                abi.encodeCall(
                    IV1CapToken.initialize,
                    (
                        "cap USD",
                        "cUSD",
                        address(v1ac),
                        makeAddr("feeAuction"),
                        makeAddr("oracle"),
                        assets,
                        makeAddr("ins")
                    )
                )
            )
        );
        stcusd = address(
            new ERC1967Proxy(v1StakedCapImpl, abi.encodeCall(IV1StakedCap.initialize, (address(v1ac), cusd, 1 days)))
        );

        vm.store(cusd, bytes32(uint256(SLOT_ERC20) + 2), bytes32(SUPPLY));
        _setBal(alice, 10_000e18);
        _setBal(bob, 10_000e18);
        _setBal(makeAddr("rest"), SUPPLY - 20_000e18);
        usdc.mint(cusd, ON_HAND_USDC);

        vm.startPrank(alice);
        IERC20(cusd).approve(stcusd, type(uint256).max);
        IERC4626(stcusd).deposit(5_000e18, alice);
        vm.stopPrank();

        headStablecoin = address(new Stablecoin());
        headWrapper = address(new Wrapper());
        migrator = address(new Migrator());
    }

    function _setBal(address who, uint256 amount) internal {
        vm.store(cusd, keccak256(abi.encode(who, SLOT_ERC20)), bytes32(amount));
    }

    /// @dev The two-step path the v1 timelock can execute today with no change to HEAD.
    function _twoStepMigrate() internal {
        // cUSD: v1 -> Migrator (+migrate) -> HEAD Stablecoin
        UUPSUpgradeable(cusd)
            .upgradeToAndCall(
                migrator,
                abi.encodeCall(
                    Migrator.migrateStablecoin, (address(manager), address(usdc), 6, address(irm), address(0))
                )
            );
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, ""); // authorised by HEAD `restricted` via manager
        // stcUSD: v1 -> Migrator (+migrate, opts in on the now-HEAD cUSD) -> HEAD Wrapper
        UUPSUpgradeable(stcusd)
            .upgradeToAndCall(migrator, abi.encodeCall(Migrator.migrateWrapper, (address(manager), cusd)));
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, "");
    }
}

contract U1_Verify is U_VerifyBase {
    // (c) v1 wrote OZ 5.x namespaced Initializable at the slot HEAD reads; value is 1 on both proxies.
    function test_c_v1InitializableIsNamespacedAndSetTo1() public view {
        assertEq(uint256(vm.load(cusd, SLOT_INIT)), 1, "cUSD _initialized");
        assertEq(uint256(vm.load(stcusd, SLOT_INIT)), 1, "stcUSD _initialized");
        // slot 0 of the linear layout is untouched: v1 was fully namespaced, not OZ 4.x
        assertEq(uint256(vm.load(cusd, bytes32(0))), 0, "cUSD slot0");
    }

    // (c) so HEAD `initialize` can never run on either proxy, with or without atomic upgradeToAndCall
    function test_c_initializeRevertsOnBothProxies() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(cusd)
            .upgradeToAndCall(
                headStablecoin,
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(manager), address(usdc), "cap USD", "cUSD", address(irm), address(0))
                )
            );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(stcusd)
            .upgradeToAndCall(headWrapper, abi.encodeCall(Wrapper.initialize, (address(manager), cusd)));

        // and a bare upgrade followed by initialize() as a separate tx: same revert
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Stablecoin(cusd).initialize(address(manager), address(usdc), "cap USD", "cUSD", address(irm), address(0));
    }

    // (d) every namespace HEAD introduces is zero on a live v1 proxy (no overlap => no data either)
    function test_d_headNamespacesAreEmptyOnV1Proxies() public view {
        bytes32 sb = _erc7201("cap.storage.Stablecoin");
        assertEq(sb, Migrator(migrator).stablecoinBase(), "erc7201 helper");
        for (uint256 i; i < 8; i++) {
            assertEq(vm.load(cusd, bytes32(uint256(sb) + i)), bytes32(0), "cap.storage.Stablecoin slot");
            assertEq(vm.load(cusd, bytes32(uint256(SLOT_PREMIUM_VESTING) + i)), bytes32(0), "PremiumVesting slot");
            assertEq(vm.load(cusd, bytes32(uint256(SLOT_ERC7540) + i)), bytes32(0), "ERC7540AsyncRedeem slot");
            assertEq(vm.load(cusd, bytes32(uint256(_erc7201("cap.storage.ERC7540Operator")) + i)), bytes32(0), "op");
        }
        assertEq(vm.load(cusd, SLOT_ACCESS_MANAGED), bytes32(0), "cUSD AccessManaged");
        assertEq(vm.load(cusd, SLOT_ERC4626), bytes32(0), "cUSD ERC4626 (v1 CapToken is not an ERC4626)");
        assertEq(vm.load(stcusd, SLOT_ACCESS_MANAGED), bytes32(0), "stcUSD AccessManaged");
        // stcUSD's ERC4626 namespace DOES survive: v1 StakedCap is OZ ERC4626Upgradeable
        assertEq(address(uint160(uint256(vm.load(stcusd, SLOT_ERC4626)))), cusd, "stcUSD ERC4626._asset == cUSD");
        // and the v1 namespaces HEAD never touches are populated
        assertEq(address(uint160(uint256(vm.load(cusd, SLOT_V1_ACCESS)))), address(v1ac), "cap.storage.Access");
    }

    // (d) bare upgrade: exact numbers from the finding re-derived
    function test_d_bareUpgradeNumbers() public {
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
        Stablecoin c = Stablecoin(cusd);
        assertEq(c.asset(), address(0));
        assertEq(c.underlyingDecimals(), 0);
        assertEq(c.authority(), address(0));
        assertEq(c.totalSupply(), SUPPLY, "balances survive");
        assertEq(c.balanceOf(alice), 5_000e18, "alice balance survives");
        assertEq(c.totalAssets(), SUPPLY / 1e18, "totalAssets = backing*10^0/10^18");
        assertEq(c.previewDeposit(1e6), 1e24, "previewDeposit(1 USDC)");
        assertEq(c.previewMint(1e18), 1, "previewMint(1 cUSD)");
        vm.prank(alice);
        vm.expectRevert(); // balanceOf on address(0) asset
        c.instantRedeem(1e18, alice, alice);
        vm.prank(alice);
        vm.expectRevert();
        c.deposit(1e6, alice);
        // requestRedeem strands shares: it succeeds, but nothing downstream can ever read the queue
        vm.prank(alice);
        c.requestRedeem(1_000e18, alice, alice);
        assertEq(c.balanceOf(alice), 4_000e18, "shares left alice");
        vm.expectRevert();
        c.claimableRedeemRequest(1, alice);
    }

    // (b) THE ATTACK ON "PERMANENT / NO PATH": two-step migration through an out-of-tree Migrator works
    //     with HEAD unchanged, and leaves both proxies upgradeable through the new AccessManager.
    function test_b_twoStepMigrationFullyRecoversBothProxies() public {
        _twoStepMigrate();
        Stablecoin c = Stablecoin(cusd);
        Wrapper w = Wrapper(stcusd);

        // wiring
        assertEq(c.asset(), address(usdc), "asset");
        assertEq(c.underlyingDecimals(), 6, "underlyingDecimals");
        assertEq(c.irm(), address(irm), "irm");
        assertEq(c.reserveVault(), address(0), "reserveVault");
        assertEq(c.stablecoin(), cusd, "stablecoin()");
        assertEq(c.authority(), address(manager), "cUSD authority");
        assertEq(w.authority(), address(manager), "stcUSD authority");
        assertEq(w.asset(), cusd, "wrapper asset survives from v1 ERC4626 namespace");
        assertTrue(c.optedIn(stcusd), "wrapper opted in");
        assertEq(c.name(), "cap USD");
        assertEq(c.symbol(), "cUSD");
        assertEq(c.decimals(), 18);
        assertEq(c.creditBackedSupply(), 0);
        assertEq(c.badDebt(), 0);
        assertEq(c.totalSupply(), SUPPLY);
        assertEq(c.totalAssets(), SUPPLY / 1e12, "totalAssets at par in USDC units");
        assertEq(c.previewDeposit(1e6), 1e18);

        // holder redeem works
        vm.prank(alice);
        uint256 got = c.instantRedeem(1e18, alice, alice);
        assertEq(got, 1e6, "1 cUSD -> 1 USDC");
        assertEq(usdc.balanceOf(alice), 1e6);

        // deposit works
        usdc.mint(bob, 5e6);
        vm.startPrank(bob);
        usdc.approve(cusd, 5e6);
        uint256 shares = c.deposit(5e6, bob);
        vm.stopPrank();
        assertEq(shares, 5e18);

        // wrapper deposit / redeem work
        vm.startPrank(bob);
        IERC20(cusd).approve(stcusd, type(uint256).max);
        uint256 wshares = IERC4626(stcusd).deposit(1e18, bob);
        assertGt(wshares, 0);
        IERC4626(stcusd).redeem(wshares, bob, bob);
        vm.stopPrank();

        // restricted functions and further upgrades now work through the AccessManager (admin = this)
        c.mintCreditBacked(bob, 1e18);
        assertEq(c.creditBackedSupply(), 1e18);
        UUPSUpgradeable(cusd).upgradeToAndCall(address(new Stablecoin()), "");
        UUPSUpgradeable(stcusd).upgradeToAndCall(address(new Wrapper()), "");

        // and nobody else can upgrade
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
    }

    // (b) the same Migrator is useless once the bare upgrade has landed: the escape hatch closes
    function test_b_migratorCannotBeAppliedAfterBareUpgrade() public {
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        UUPSUpgradeable(cusd)
            .upgradeToAndCall(
                migrator,
                abi.encodeCall(
                    Migrator.migrateStablecoin, (address(manager), address(usdc), 6, address(irm), address(0))
                )
            );
    }
}
