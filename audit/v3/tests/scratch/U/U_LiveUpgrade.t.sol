// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Workstream U - live-proxy upgrade compatibility. Mainnet fork of the REAL cUSD / stcUSD proxies.
// Run:  FOUNDRY_TEST=audit/v3/tests/scratch/U forge test --match-path 'audit/v3/tests/scratch/U/*' -vv
// Env:  U_RPC (default https://ethereum-rpc.publicnode.com), U_BLOCK (default = pinned block below; 0 = latest)
//
// Tests named test_FAIL_* assert the behaviour the upgrade is supposed to have and therefore FAIL
// on current code; test_TABLE_* pass and print the post-upgrade behaviour of every user-facing call.

import { InterestRateModel } from "../../../../../contracts/cap/InterestRateModel.sol";
import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { IPremiumVesting } from "../../../../../contracts/interfaces/IPremiumVesting.sol";
import { StablecoinV2 } from "./StablecoinV2.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

interface IV1Vault {
    function totalSupplies(address) external view returns (uint256);
    function totalBorrows(address) external view returns (uint256);
    function loaned(address) external view returns (uint256);
    function fractionalReserveVault(address) external view returns (address);
    function repay(address, uint256) external;
    function divestAll(address) external;
    function assets() external view returns (address[] memory);
}

interface IV1StakedCap {
    function storedTotal() external view returns (uint256);
    function lockedProfit() external view returns (uint256);
}

contract U_LiveUpgrade is Test {
    address constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
    address constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WWTGXX = 0x434558CB1EBe9950e8A66f1ef8A15A473Dce7D8c;
    address constant V1_ACCESS_CONTROL = 0x7731129a10d51e18cDE607C5C115F26503D2c683;
    address constant V1_TIMELOCK = 0xD8236031d8279d82E615aF2BFab5FC0127A329ab; // holder of role(bytes4(0), cUSD/stcUSD)
    address constant V1_LENDER = 0x15622c3dbbc5614E6DFa9446603c1779647f01FC; // holder of role(repay, cUSD)
    address constant FR_USDC = 0x3Ed6aa32c930253fc990dE58fF882B9186cd0072; // v1 fractional-reserve vault "cap USDC"
    address constant FR_WWTGXX = 0xb1c1C80FDbBde5B40264e1410550F3C864113bF8;

    bytes32 constant SLOT_INIT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant SLOT_ERC4626 = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
    bytes32 constant SLOT_ACCESS_MANAGED = 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00;
    bytes32 constant SLOT_V1_ACCESS = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;

    Stablecoin cusd = Stablecoin(CUSD);
    Wrapper stcusd = Wrapper(STCUSD);
    address stablecoinImpl;
    address wrapperImpl;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 supplyBefore;
    uint256 stTotalAssetsBefore;
    uint256 stSupplyBefore;
    uint256 v1UsdcBorrows;
    uint256 v1UsdcLoaned;

    function setUp() public {
        string memory rpc = vm.envOr("U_RPC", string("https://ethereum-rpc.publicnode.com"));
        uint256 blk = vm.envOr("U_BLOCK", uint256(25976879));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);

        stablecoinImpl = address(new Stablecoin());
        wrapperImpl = address(new Wrapper());

        supplyBefore = cusd.totalSupply();
        stTotalAssetsBefore = stcusd.totalAssets();
        stSupplyBefore = stcusd.totalSupply();

        v1UsdcBorrows = IV1Vault(CUSD).totalBorrows(USDC);
        v1UsdcLoaned = IV1Vault(CUSD).loaned(USDC);

        // two cUSD holders (balances written into the OZ ERC20 namespace; supply untouched)
        deal(CUSD, alice, 10_000e18);
        deal(CUSD, bob, 10_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _upgradeCusd(bytes memory data) internal {
        vm.prank(V1_TIMELOCK);
        UUPSUpgradeable(CUSD).upgradeToAndCall(stablecoinImpl, data);
    }

    function _upgradeStcusd(bytes memory data) internal {
        vm.prank(V1_TIMELOCK);
        UUPSUpgradeable(STCUSD).upgradeToAndCall(wrapperImpl, data);
    }

    function _row(string memory label, address target, bytes memory data) internal returns (bool ok) {
        bytes memory ret;
        (ok, ret) = target.call(data);
        string memory verdict = ok ? "WORKS" : "REVERTS";
        if (ok && ret.length == 32) {
            console2.log(string.concat("  ", label, " -> ", verdict), abi.decode(ret, (uint256)));
        } else if (!ok && ret.length >= 4) {
            console2.log(string.concat("  ", label, " -> ", verdict), vm.toString(bytes4(ret)));
        } else {
            console2.log(string.concat("  ", label, " -> ", verdict));
        }
    }

    function _deployAccessManagerAndIrm() internal returns (address am, address irm) {
        am = address(new AccessManager(address(this)));
        InterestRateModel irmImpl = new InterestRateModel();
        irm = address(
            new ERC1967Proxy(
                address(irmImpl),
                abi.encodeCall(InterestRateModel.initialize, (am, CUSD, 1e27, 2e27, 1e27, 0.02e27, 1 hours))
            )
        );
    }

    // ---------------------------------------------------------------- 0. live state sanity

    function test_TABLE_0_liveState() public view {
        console2.log("block", block.number);
        console2.log("cUSD impl slot", vm.toString(vm.load(CUSD, ERC1967Utils_IMPL())));
        console2.log("cUSD live impl code length", 0xa76645E15c267b876999bf7689E0b2C1EE29BFE6.code.length);
        console2.log("stcUSD live impl code length", 0x42c0e0ef7C2F35de073F4d6f9c0e4483429c3D31.code.length);
        console2.log("cUSD Initializable._initialized", uint256(vm.load(CUSD, SLOT_INIT)));
        console2.log("cUSD ERC4626 namespace (asset|decimals)", vm.toString(vm.load(CUSD, SLOT_ERC4626)));
        console2.log("cUSD AccessManaged.authority", vm.toString(vm.load(CUSD, SLOT_ACCESS_MANAGED)));
        console2.log("cUSD v1 Access.accessControl", vm.toString(vm.load(CUSD, SLOT_V1_ACCESS)));
        console2.log("cUSD totalSupply", supplyBefore);
        console2.log("USDC on hand at cUSD", IERC20(USDC).balanceOf(CUSD));
        console2.log("USDC totalSupplies(v1)", IV1Vault(CUSD).totalSupplies(USDC));
        console2.log("USDC totalBorrows(v1, on loan to agents)", IV1Vault(CUSD).totalBorrows(USDC));
        console2.log("USDC loaned to FR vault(v1)", IV1Vault(CUSD).loaned(USDC));
        console2.log("FR_USDC.maxWithdraw(cUSD)", IERC4626(FR_USDC).maxWithdraw(CUSD));
        console2.log("wWTGXX on hand at cUSD", IERC20(WWTGXX).balanceOf(CUSD));
        console2.log("FR_WWTGXX.maxWithdraw(cUSD)", IERC4626(FR_WWTGXX).maxWithdraw(CUSD));
        console2.log("stcUSD impl slot", vm.toString(vm.load(STCUSD, ERC1967Utils_IMPL())));
        console2.log("stcUSD Initializable._initialized", uint256(vm.load(STCUSD, SLOT_INIT)));
        console2.log("stcUSD ERC4626 namespace (asset|decimals)", vm.toString(vm.load(STCUSD, SLOT_ERC4626)));
        console2.log("stcUSD totalAssets (v1: storedTotal - lockedProfit)", stTotalAssetsBefore);
        console2.log(
            "stcUSD storedTotal (cap.storage.StakedCap slot 0)",
            uint256(vm.load(STCUSD, 0xc3a6ec7b30f1d79063d00dcbb5942b226b77fe48a28f1a19018e7d1f70fd7600))
        );
        console2.log("stcUSD lockedProfit", IV1StakedCap(STCUSD).lockedProfit());
        console2.log("cUSD.balanceOf(stcUSD)", IERC20(CUSD).balanceOf(STCUSD));
    }

    function ERC1967Utils_IMPL() internal pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    // ---------------------------------------------------------------- 1. initializer reverts on the live proxy

    /// Expected: `Stablecoin.initialize` can be run as the upgrade call. Actual: InvalidInitialization.
    function test_FAIL_1_initializeRunsOnLiveCusd() public {
        (address am, address irm) = _deployAccessManagerAndIrm();
        _upgradeCusd(abi.encodeCall(Stablecoin.initialize, (am, USDC, "cap USD", "cUSD", irm, address(0))));
        assertEq(cusd.asset(), USDC);
    }

    /// Expected: `Wrapper.initialize` can be run as the upgrade call. Actual: InvalidInitialization.
    function test_FAIL_1b_initializeRunsOnLiveStcusd() public {
        _upgradeCusd("");
        address am = address(new AccessManager(address(this)));
        _upgradeStcusd(abi.encodeCall(Wrapper.initialize, (am, CUSD)));
        assertTrue(IPremiumVesting(CUSD).optedIn(STCUSD));
    }

    function test_TABLE_1_initializeRevertSelectors() public {
        (address am, address irm) = _deployAccessManagerAndIrm();
        vm.prank(V1_TIMELOCK);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(CUSD)
            .upgradeToAndCall(
                stablecoinImpl, abi.encodeCall(Stablecoin.initialize, (am, USDC, "cap USD", "cUSD", irm, address(0)))
            );
        vm.prank(V1_TIMELOCK);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(STCUSD).upgradeToAndCall(wrapperImpl, abi.encodeCall(Wrapper.initialize, (am, CUSD)));
        console2.log("both initializers revert InvalidInitialization() on the live proxies (_initialized == 1)");
    }

    // ---------------------------------------------------------------- 2. bare upgrade: behaviour table

    /// Expected: the ERC4626 asset survives the upgrade. Actual: v1 CapToken never had one -> address(0).
    function test_FAIL_2_assetAndDecimalsSurvive() public {
        _upgradeCusd("");
        assertEq(cusd.asset(), USDC, "asset");
        assertEq(cusd.underlyingDecimals(), 6, "underlyingDecimals");
    }

    /// Expected: a holder can still redeem after the upgrade. Actual: unlockedSupply() reverts.
    function test_FAIL_2b_holderCanRedeem() public {
        _upgradeCusd("");
        vm.prank(alice);
        cusd.instantRedeem(1e18, alice, alice);
    }

    function test_TABLE_2_bareUpgradeBehaviour() public {
        _upgradeCusd("");
        console2.log("== cUSD after upgradeToAndCall(Stablecoin, \"\") by the v1 timelock ==");
        console2.log("  name()", cusd.name());
        console2.log("  symbol()", cusd.symbol());
        console2.log("  decimals()", cusd.decimals());
        console2.log("  totalSupply() unchanged", cusd.totalSupply() == supplyBefore);
        console2.log("  balanceOf(alice)", cusd.balanceOf(alice));
        console2.log("  asset()", cusd.asset());
        console2.log("  underlyingDecimals()", cusd.underlyingDecimals());
        console2.log("  irm()", cusd.irm());
        console2.log("  reserveVault()", cusd.reserveVault());
        console2.log("  authority()", cusd.authority());
        console2.log("  stablecoin() [PremiumVesting]", cusd.stablecoin());
        console2.log("  creditBackedSupply()", cusd.creditBackedSupply());
        console2.log("  badDebt()", cusd.badDebt());
        console2.log("  backing()", cusd.backing());
        console2.log("  utilizationRate()", cusd.utilizationRate());
        console2.log("  totalAssets() [WRONG: S/1e18]", cusd.totalAssets());
        console2.log("  previewDeposit(1e6 USDC) [WRONG]", cusd.previewDeposit(1e6));
        console2.log("  previewMint(1e18 cUSD) [WRONG]", cusd.previewMint(1e18));
        console2.log("  convertToAssets(1e18) [WRONG]", cusd.convertToAssets(1e18));
        console2.log("  convertToShares(1e6) [WRONG]", cusd.convertToShares(1e6));
        console2.log("  maxDeposit(alice)", cusd.maxDeposit(alice));

        _row("unlockedSupply()", CUSD, abi.encodeCall(cusd.unlockedSupply, ()));
        _row("instantUnlockedSupply()", CUSD, abi.encodeCall(cusd.instantUnlockedSupply, ()));
        _row("maxRedeem(alice)", CUSD, abi.encodeCall(cusd.maxRedeem, (alice)));
        _row("maxInstantRedeem(alice)", CUSD, abi.encodeCall(cusd.maxInstantRedeem, (alice)));
        _row("claimable(stcUSD)", CUSD, abi.encodeCall(cusd.claimable, (STCUSD)));
        _row("vested()", CUSD, abi.encodeCall(cusd.vested, ()));

        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(CUSD, type(uint256).max);
        _row("deposit(1000e6, alice)", CUSD, abi.encodeCall(cusd.deposit, (1_000e6, alice)));
        _row("mint(1e18, alice)", CUSD, abi.encodeCall(cusd.mint, (1e18, alice)));
        _row("fund(1e6)", CUSD, abi.encodeCall(cusd.fund, (1e6)));
        _row("instantRedeem(1e18)", CUSD, abi.encodeCall(cusd.instantRedeem, (1e18, alice, alice)));
        _row("instantWithdraw(1)", CUSD, abi.encodeCall(cusd.instantWithdraw, (1, alice, alice)));
        _row(
            "requestRedeem(5000e18) [shares leave alice]",
            CUSD,
            abi.encodeCall(cusd.requestRedeem, (5_000e18, alice, alice))
        );
        _row("balanceOf(alice) after request", CUSD, abi.encodeCall(cusd.balanceOf, (alice)));
        _row(
            "redeem(1,alice,alice) 3-arg",
            CUSD,
            abi.encodeWithSignature("redeem(uint256,address,address)", 1, alice, alice)
        );
        _row(
            "redeem(1,1,alice,alice) 4-arg",
            CUSD,
            abi.encodeWithSignature("redeem(uint256,uint256,address,address)", 1, 1, alice, alice)
        );
        _row("claimableRedeemRequest(1,alice)", CUSD, abi.encodeCall(cusd.claimableRedeemRequest, (1, alice)));
        _row("transfer(bob, 1e18)", CUSD, abi.encodeCall(IERC20.transfer, (bob, 1e18)));
        _row("approve(bob, 1e18)", CUSD, abi.encodeCall(IERC20.approve, (bob, 1e18)));
        _row("optIn()", CUSD, abi.encodeCall(cusd.optIn, ()));
        _row("claim(alice)", CUSD, abi.encodeCall(cusd.claim, (alice)));
        _row("coverBadDebt(1)", CUSD, abi.encodeCall(cusd.coverBadDebt, (1)));
        _row(
            "permit(...) [v1 selector, gone]",
            CUSD,
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                alice,
                bob,
                1,
                0,
                0,
                bytes32(0),
                bytes32(0)
            )
        );
        _row("nonces(alice) [v1 selector, gone]", CUSD, abi.encodeWithSignature("nonces(address)", alice));
        _row("DOMAIN_SEPARATOR() [v1 selector, gone]", CUSD, abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        vm.stopPrank();

        vm.startPrank(V1_TIMELOCK);
        _row("mintCreditBacked (restricted, timelock)", CUSD, abi.encodeCall(cusd.mintCreditBacked, (alice, 1)));
        _row("setReserveVault (restricted, timelock)", CUSD, abi.encodeCall(cusd.setReserveVault, (alice)));
        _row("recognizeBadDebtInReserve (restricted)", CUSD, abi.encodeCall(cusd.recognizeBadDebtInReserve, (1)));
        _row("invest(1) (restricted)", CUSD, abi.encodeCall(cusd.invest, (1)));
        _row("setAuthority(am) (timelock)", CUSD, abi.encodeCall(IAccessManaged.setAuthority, (V1_ACCESS_CONTROL)));
        _row(
            "upgradeToAndCall(again) (timelock) [BRICKED]",
            CUSD,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (stablecoinImpl, ""))
        );
        _row("divestAll(USDC) [v1 selector, gone]", CUSD, abi.encodeCall(IV1Vault.divestAll, (USDC)));
        vm.stopPrank();
        vm.prank(V1_LENDER);
        _row("Lender -> repay(USDC, 1) [v1 selector, gone]", CUSD, abi.encodeCall(IV1Vault.repay, (USDC, 1)));
    }

    // ---------------------------------------------------------------- 3. bricked upgrade authority

    /// Expected: the timelock that performed the upgrade can upgrade again. Actual: authority()==0 -> AccessManagedUnauthorized.
    function test_FAIL_3_proxyStillUpgradeable() public {
        _upgradeCusd("");
        assertEq(cusd.authority(), V1_ACCESS_CONTROL, "authority should be the live access control");
        _upgradeCusd("");
    }

    function test_TABLE_3_upgradeBrickedSelectors() public {
        _upgradeCusd("");
        vm.prank(V1_TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, V1_TIMELOCK));
        UUPSUpgradeable(CUSD).upgradeToAndCall(stablecoinImpl, "");
        vm.prank(V1_TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, V1_TIMELOCK));
        IAccessManaged(CUSD).setAuthority(V1_ACCESS_CONTROL);

        _upgradeStcusd("");
        vm.prank(V1_TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, V1_TIMELOCK));
        UUPSUpgradeable(STCUSD).upgradeToAndCall(wrapperImpl, "");
        console2.log(
            "cUSD and stcUSD: second upgradeToAndCall and setAuthority revert AccessManagedUnauthorized(timelock)"
        );
    }

    // ---------------------------------------------------------------- 4. stcUSD

    /// Expected: stcUSD is opted in to premium after the upgrade (Wrapper.initialize does this). Actual: false, and unfixable.
    function test_FAIL_4_wrapperOptedIn() public {
        _upgradeCusd("");
        _upgradeStcusd("");
        assertTrue(IPremiumVesting(CUSD).optedIn(STCUSD), "stcUSD opted in");
    }

    /// Expected: stcUSD deposits keep working after both upgrades. Actual: claim() -> IERC20(0).balanceOf reverts.
    function test_FAIL_4b_wrapperDepositWorks() public {
        _upgradeCusd("");
        _upgradeStcusd("");
        vm.startPrank(alice);
        IERC20(CUSD).approve(STCUSD, type(uint256).max);
        stcusd.deposit(1e18, alice);
        vm.stopPrank();
    }

    function test_TABLE_4_stcusdBehaviour() public {
        // order A: stcUSD first
        _upgradeStcusd("");
        console2.log("== stcUSD upgraded BEFORE cUSD ==");
        _row("totalAssets() [v1 cUSD has no claimable()]", STCUSD, abi.encodeCall(stcusd.totalAssets, ()));
        _row("convertToAssets(1e18)", STCUSD, abi.encodeCall(stcusd.convertToAssets, (1e18)));
        _row("maxWithdraw(alice)", STCUSD, abi.encodeCall(stcusd.maxWithdraw, (alice)));

        _upgradeCusd("");
        console2.log("== both upgraded (bare) ==");
        console2.log("  stcUSD totalAssets before upgrade (v1)", stTotalAssetsBefore);
        console2.log("  stcUSD totalAssets after upgrade", stcusd.totalAssets());
        console2.log("  = cUSD.balanceOf(stcUSD)", IERC20(CUSD).balanceOf(STCUSD));
        if (stcusd.totalAssets() >= stTotalAssetsBefore) {
            console2.log(
                "  jump (cUSD, released lockedProfit + un-notified)", stcusd.totalAssets() - stTotalAssetsBefore
            );
        } else {
            console2.log("  drop (cUSD)", stTotalAssetsBefore - stcusd.totalAssets());
        }
        console2.log("  share price before (1e18 stcUSD -> cUSD)", stTotalAssetsBefore * 1e18 / stSupplyBefore);
        console2.log("  share price after", stcusd.convertToAssets(1e18));
        console2.log("  cUSD.optedIn(stcUSD)", IPremiumVesting(CUSD).optedIn(STCUSD));
        console2.log("  cUSD.stakedSupply()", IPremiumVesting(CUSD).stakedSupply());
        console2.log("  stcUSD.authority()", stcusd.authority());
        console2.log("  stcUSD name/symbol/decimals", stcusd.name(), stcusd.symbol(), stcusd.decimals());
        vm.startPrank(alice);
        IERC20(CUSD).approve(STCUSD, type(uint256).max);
        _row("stcUSD.deposit(1e18)", STCUSD, abi.encodeCall(stcusd.deposit, (1e18, alice)));
        _row("stcUSD.mint(1e18)", STCUSD, abi.encodeCall(stcusd.mint, (1e18, alice)));
        vm.stopPrank();
        vm.startPrank(STCUSD);
        _row("cUSD.optIn() as stcUSD [no caller exists on-chain]", CUSD, abi.encodeCall(cusd.optIn, ()));
        vm.stopPrank();
        address holder = 0xA62571EbdFfAbC3051a2e5B9e1f57b23D830c8Fd; // v1 stcUSD OFT lockbox? try; fall back to stcUSD total
        uint256 hb = stcusd.balanceOf(holder);
        console2.log("  stcUSD.balanceOf(0xA625.. lockbox)", hb);
        if (hb > 0) {
            vm.startPrank(holder);
            _row("stcUSD.redeem(1e18) by a real holder", STCUSD, abi.encodeCall(stcusd.redeem, (1e18, holder, holder)));
            _row(
                "stcUSD.withdraw(1e18) by a real holder",
                STCUSD,
                abi.encodeCall(stcusd.withdraw, (1e18, holder, holder))
            );
            vm.stopPrank();
        }
        _row(
            "stcUSD.permit(...) [kept: HEAD Wrapper has ERC20Permit]",
            STCUSD,
            abi.encodeWithSignature("nonces(address)", alice)
        );
    }

    // ---------------------------------------------------------------- 5. what a reinitializer fixes, and what it cannot

    function test_TABLE_5_reinitializerLimits() public {
        (address am, address irm) = _deployAccessManagerAndIrm();
        address v2 = address(new StablecoinV2());
        vm.prank(V1_TIMELOCK);
        UUPSUpgradeable(CUSD).upgradeToAndCall(v2, abi.encodeCall(StablecoinV2.migrate, (am, USDC, irm, address(0))));
        console2.log("== cUSD upgraded with a reinitializer(2) that sets authority/asset/decimals/irm/stablecoin ==");
        console2.log("  asset()", cusd.asset());
        console2.log("  underlyingDecimals()", cusd.underlyingDecimals());
        console2.log("  authority()", cusd.authority());
        console2.log("  irm()", cusd.irm());
        console2.log("  name()/symbol() preserved", cusd.name(), cusd.symbol());
        console2.log("  totalSupply S", cusd.totalSupply());
        console2.log("  totalAssets() REPORTED (USDC, 6-dec)", cusd.totalAssets());
        console2.log("  USDC actually on hand", IERC20(USDC).balanceOf(CUSD));
        console2.log("  unlockedSupply() (cUSD redeemable right now)", cusd.unlockedSupply());
        console2.log("  USDC on loan to v1 agents (v1 view, snapshot pre-upgrade)", v1UsdcBorrows);
        console2.log(
            "  USDC in v1 FR vault (shares held by cUSD, no HEAD path to redeem)", IERC4626(FR_USDC).maxWithdraw(CUSD)
        );
        console2.log(
            "  wWTGXX on hand + FR vault (no HEAD path at all)",
            IERC20(WWTGXX).balanceOf(CUSD),
            IERC4626(FR_WWTGXX).maxWithdraw(CUSD)
        );

        // the previewed deposit and mint are now at par, deposits work
        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(CUSD, type(uint256).max);
        uint256 minted = cusd.deposit(1_000e6, alice);
        console2.log("  alice deposit(1000 USDC) -> cUSD", minted);
        vm.stopPrank();

        // bob queued before liquidity arrived; alice's fresh USDC is bob's exit liquidity
        vm.prank(bob);
        uint256 id = cusd.requestRedeem(4_000e18, bob, bob);
        console2.log("  bob requestRedeem(4000 cUSD) id", id);
        console2.log("  bob claimableRedeemRequest", cusd.claimableRedeemRequest(id, bob));
        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        cusd.redeem(id, 4_000e18, bob, bob);
        console2.log("  bob redeemed USDC", IERC20(USDC).balanceOf(bob) - usdcBefore);
        console2.log("  USDC left on hand", IERC20(USDC).balanceOf(CUSD));
        console2.log("  unlockedSupply() now", cusd.unlockedSupply());
        vm.prank(alice);
        (bool ok,) = CUSD.call(abi.encodeCall(cusd.instantRedeem, (1_000e18, alice, alice)));
        console2.log("  alice instantRedeem(1000 cUSD) ok?", ok);

        // the v1 reserve cannot be pulled through any HEAD function
        vm.startPrank(address(this));
        _row("recall(1) with reserveVault=0", CUSD, abi.encodeCall(cusd.recall, (1)));
        cusd.setReserveVault(FR_USDC);
        _row("recall(1) with reserveVault=FR_USDC (ERC4626, not Aera)", CUSD, abi.encodeCall(cusd.recall, (1)));
        vm.stopPrank();
        // the timelock can upgrade again
        vm.prank(V1_TIMELOCK);
        (ok,) = CUSD.call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (v2, "")));
        console2.log("  timelock upgrade again ok? (ADMIN of the new AccessManager needed)", ok);
        accessManagerGrant(am);
        vm.prank(V1_TIMELOCK);
        (ok,) = CUSD.call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (v2, "")));
        console2.log("  ... after granting ADMIN to the timelock ok?", ok);
    }

    /// Expected (single promise): what the token reports as backing is redeemable. Actual, even after a correct
    /// reinitializer: totalAssets() == 84.88M USDC while 3,219 USDC is on hand and no HEAD function reaches the rest.
    function test_FAIL_5_reportedBackingIsOnHand() public {
        (address am, address irm) = _deployAccessManagerAndIrm();
        address v2 = address(new StablecoinV2());
        vm.prank(V1_TIMELOCK);
        UUPSUpgradeable(CUSD).upgradeToAndCall(v2, abi.encodeCall(StablecoinV2.migrate, (am, USDC, irm, address(0))));
        assertLe(cusd.totalAssets(), IERC20(USDC).balanceOf(CUSD), "totalAssets exceeds USDC on hand");
    }

    function accessManagerGrant(address am) internal {
        AccessManager(am).grantRole(0, V1_TIMELOCK, 0);
    }
}
