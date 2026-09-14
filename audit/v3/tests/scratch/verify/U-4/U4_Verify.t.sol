// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Phase-3 adversarial verification of U-4 (offline, no RPC). Shares the v1 proxies + Migrator harness of
// ../U-1/U1_Verify.t.sol. The live reserve shape is modelled: 3,219 USDC on hand, an ERC-4626 "cap USDC"
// fractional-reserve vault whose shares cUSD holds (18,269 USDC), a second basket asset (wWTGXX) on hand,
// and 61,486 USDC "on loan" to v1 agents (simply not in the contract).
//
// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/U-4 forge test --match-path 'audit/v3/tests/scratch/verify/U-4/*' -vv
//
// Attacks on the finding:
//  (b) totalAssets() > USDC on hand is HEAD's documented design (backing at par; test/unit/cap/Stablecoin.t.sol:921
//      "accounting is not the token balance"), not a migration artefact. unlockedSupply() already caps redemptions
//      to what is on hand, so the token does not pay out what it does not have.
//  (b) v1 loan repayments need no HEAD entry point: a plain USDC transfer raises unlockedSupply 1:1. The Lender-side
//      bookkeeping lives in the v1 Lender, itself an ERC1967 proxy under the same timelock.
//  (b) "permanently stranded" is false under the finding's own precondition (correct reinitializer => authority set):
//      a follow-up upgrade recovers the FR shares and the second asset; the proxy then returns to HEAD.
//  (c) new depositors are FIFO queue liquidity at par, the same as under any invested reserve; no value is lost.

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { IAeraVault } from "../../../../../../contracts/interfaces/IAeraVault.sol";
import { MockAeraVault } from "../../../../../../test/shared/mocks/MockAeraVault.sol";
import { Migrator, U_VerifyBase } from "../U-1/U1_Verify.t.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { console2 } from "forge-std/Test.sol";

/// @dev Stand-in for the v1 fractional-reserve vault 0x3Ed6aa... ("cap USDC", ERC-4626, cUSD is the sole holder).
contract MockFrVault is ERC4626 {
    constructor(IERC20 a) ERC4626(a) ERC20("cap USDC", "capUSDC") { }
}

contract WWtgxx is ERC20 {
    constructor() ERC20("Wrapped WisdomTree Government Money Market Digital Fund", "wWTGXX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev One-off follow-up implementation the AccessManager admin can install AFTER a correct migration
///      (authority set) to pull leftover v1 positions, then step back to HEAD. Not part of HEAD.
contract RescueImpl is UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    function redeemV1Vault(address vault) external restricted returns (uint256 assets) {
        assets = IERC4626(vault).redeem(IERC20(vault).balanceOf(address(this)), address(this), address(this));
    }

    function sweep(address token, address to) external restricted {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function _authorizeUpgrade(address) internal override restricted { }
}

contract U4_Verify is U_VerifyBase {
    MockFrVault frVault;
    WWtgxx wwtgxx;
    address treasury = makeAddr("treasury");

    uint256 constant FR_USDC = 18_269e6;
    uint256 constant V1_LOANS_USDC = 61_486e6;
    uint256 constant WWTGXX_ON_HAND = 1_716e18;

    function setUp() public override {
        super.setUp(); // ON_HAND_USDC = 3,219e6 already at cusd
        frVault = new MockFrVault(IERC20(address(usdc)));
        usdc.mint(address(this), FR_USDC);
        usdc.approve(address(frVault), FR_USDC);
        frVault.deposit(FR_USDC, cusd); // cUSD is the only shareholder, as on chain
        wwtgxx = new WWtgxx();
        wwtgxx.mint(cusd, WWTGXX_ON_HAND);
    }

    function _migrate() internal {
        _twoStepMigrate();
    }

    // ---------------------------------------------------------------- (b) reported vs on hand is HEAD's design

    function test_b_reportedBackingAboveOnHand_isHeadDesignNotMigrationSpecific() public {
        _migrate();
        Stablecoin c = Stablecoin(cusd);
        assertEq(c.totalAssets(), SUPPLY / 1e12, "par backing reported (finding's number)");
        assertEq(c.unlockedSupply(), ON_HAND_USDC * 1e12, "but only what is on hand is redeemable");
        assertEq(c.maxInstantRedeem(alice), 5_000e18 < ON_HAND_USDC * 1e12 ? 5_000e18 : ON_HAND_USDC * 1e12);

        // the same "violation" of the author's expected invariant on a FRESH HEAD deployment after invest():
        MockAeraVault aera = new MockAeraVault();
        address fresh = address(
            new ERC1967Proxy(
                headStablecoin,
                abi.encodeCall(
                    Stablecoin.initialize, (address(manager), address(usdc), "x", "x", address(irm), address(aera))
                )
            )
        );
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(fresh, 1_000e6);
        Stablecoin(fresh).deposit(1_000e6, bob);
        vm.stopPrank();
        Stablecoin(fresh).invest(400e6);
        assertEq(Stablecoin(fresh).totalAssets(), 1_000e6, "totalAssets unchanged by invest (HEAD design)");
        assertEq(usdc.balanceOf(fresh), 600e6);
        assertGt(
            Stablecoin(fresh).totalAssets(),
            usdc.balanceOf(fresh),
            "author's test_FAIL_5 predicate fails on plain HEAD too"
        );
        assertEq(Stablecoin(fresh).unlockedSupply(), 600e18, "and unlockedSupply caps to on hand there as well");
    }

    // ---------------------------------------------------------------- (b) loans: a plain transfer is the entry point

    function test_b_plainUsdcTransferRaisesUnlockedSupplyOneToOne() public {
        _migrate();
        Stablecoin c = Stablecoin(cusd);
        uint256 before = c.unlockedSupply();
        // a v1 agent (or a patched v1 Lender) repays by transferring USDC to the proxy
        usdc.mint(address(this), V1_LOANS_USDC);
        usdc.transfer(cusd, V1_LOANS_USDC);
        assertEq(c.unlockedSupply() - before, V1_LOANS_USDC * 1e12, "repayments become redeemable 1:1");
        assertEq(c.totalAssets(), SUPPLY / 1e12, "reported backing unchanged: it was never counted twice");
        // HEAD cannot record the loan-side state: utilization reads 0 while 61.5M is out
        assertEq(c.utilizationRate(), 0, "v1 loans are invisible to the IRM (the genuine gap)");
    }

    // ---------------------------------------------------------------- (b) leftovers are recoverable by a follow-up upgrade

    function test_b_leftoverV1PositionsAreNotPermanentlyStranded() public {
        _migrate();
        Stablecoin c = Stablecoin(cusd);
        assertEq(frVault.balanceOf(cusd), frVault.totalSupply(), "cUSD holds all FR shares");
        assertEq(frVault.maxWithdraw(cusd), FR_USDC);

        // HEAD as shipped: no path (finding is right about this part)
        vm.expectRevert(); // reserveVault == 0
        c.recall(1);
        c.setReserveVault(address(frVault));
        vm.expectRevert(); // ERC-4626 has no withdraw((address,uint256)[])
        c.recall(1);
        c.setReserveVault(address(0));

        // but the proxy is upgradeable (authority set by the correct migration), so a one-off follow-up recovers it
        address rescue = address(new RescueImpl());
        UUPSUpgradeable(cusd).upgradeToAndCall(rescue, "");
        uint256 got = RescueImpl(cusd).redeemV1Vault(address(frVault));
        assertEq(got, FR_USDC, "FR position redeemed to the proxy");
        RescueImpl(cusd).sweep(address(wwtgxx), treasury); // second asset out for conversion / burn-and-redistribute
        assertEq(wwtgxx.balanceOf(treasury), WWTGXX_ON_HAND);
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");

        // back on HEAD with the reserve on hand
        assertEq(c.asset(), address(usdc));
        assertEq(c.authority(), address(manager));
        assertEq(usdc.balanceOf(cusd), ON_HAND_USDC + FR_USDC);
        assertEq(c.unlockedSupply(), (ON_HAND_USDC + FR_USDC) * 1e12);
        vm.prank(alice);
        assertEq(c.instantRedeem(1e18, alice, alice), 1e6, "redeem at par");
        console2.log("USDC on hand after follow-up upgrade", usdc.balanceOf(cusd));
    }

    // ---------------------------------------------------------------- (c) depositors are FIFO liquidity at par, not a loss

    function test_c_newDepositIsQueueLiquidityAtPar_noValueLost() public {
        _migrate();
        Stablecoin c = Stablecoin(cusd);

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(cusd, 1_000e6);
        assertEq(c.deposit(1_000e6, alice), 1_000e18, "par in");
        vm.stopPrank();

        vm.prank(bob);
        uint256 idB = c.requestRedeem(4_000e18, bob, bob);
        assertEq(c.claimableRedeemRequest(idB, bob), 4_000e18, "bob's request is fully claimable against alice's USDC");
        vm.prank(bob);
        c.redeem(idB, 4_000e18, bob, bob);
        assertEq(usdc.balanceOf(bob), 4_000e6, "par out");
        assertEq(c.unlockedSupply(), 219e18, "3,219 + 1,000 - 4,000 on hand");

        // alice cannot exit instantly (finding), but she is behind bob in a FIFO queue, not short-changed
        vm.prank(alice);
        vm.expectRevert();
        c.instantRedeem(1_000e18, alice, alice);
        vm.prank(alice);
        uint256 idA = c.requestRedeem(1_000e18, alice, alice);
        assertEq(c.claimableRedeemRequest(idA, alice), 219e18, "what is on hand, now");

        // liquidity arrives (a repayment); alice completes at par
        usdc.mint(address(this), 10_000e6);
        usdc.transfer(cusd, 10_000e6);
        assertEq(c.claimableRedeemRequest(idA, alice), 1_000e18);
        vm.prank(alice);
        c.redeem(idA, 1_000e18, alice, alice);
        assertEq(usdc.balanceOf(alice), 1_000e6, "alice whole at par");
    }
}
