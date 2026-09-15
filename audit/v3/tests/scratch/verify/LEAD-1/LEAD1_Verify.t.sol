// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { IOracle } from "../../../../../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../../../../../contracts/interfaces/IRegistry.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../../../test/shared/CapRoles.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// Adversarial verification of LEAD-1 (P14): owner appends a junior in another priced asset and
/// exits the senior while debt is out. Questions: is USD coverage preserved at the swap? is the
/// lock partial when the substitute is short? is `createTranche` even the enabling primitive?
/// does GOVERNOR's feed whitelist bound the asset set? is there an event?
contract LEAD1_Verify is CapDeployer {
    address eve = makeAddr("eve");
    uint64 eveRole;
    address market;
    address[] tranches;

    uint256 constant DEBT = 500_000e18;
    uint256 constant WETH_IN = 1_000_000e18;
    // ceil(500k / 0.7) — the USD the waterfall must keep while the line is drawn
    uint256 constant REQUIRED = 714_285_714_285_714_285_714_286;

    function setUp() public {
        _deployCap();
        accessManager.grantRole(CapRoles.WHITELISTED, eve, 0);
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = eve;
        vm.prank(eve);
        eveRole = registry.createChildRoles(CapRoles.GOVERNOR, members)[0];
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _eveMarket(address[] memory assets, uint256[] memory weights) internal {
        vm.prank(eve);
        (market, tranches) = registry.createFloatingMarket(assets, weights, "Eve", eveRole);
        vm.startPrank(eve);
        FloatingMarket(market).setLtv(capConfig.defaultLt - capConfig.defaultBuffer); // 0.7
        FloatingMarket(market).setBorrowerRole(eveRole);
        vm.stopPrank();
    }

    function _eveDeposits(address tranche, address asset, uint256 amount) internal {
        uint64 depRole = accessManager.getTargetFunctionRole(tranche, IERC4626.deposit.selector);
        vm.prank(eve);
        accessManager.grantRole(depRole, eve, 0);
        MockERC20(asset).mint(eve, amount);
        vm.startPrank(eve);
        MockERC20(asset).approve(address(vault), type(uint256).max);
        vault.deposit(asset, amount, eve);
        vault.setOperator(tranche, true);
        Tranche(tranche).deposit(amount, eve);
        vm.stopPrank();
    }

    function _singleWethMarketSizedAndDrawn() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        _eveMarket(assets, w);
        _eveDeposits(tranches[0], address(collateral), WETH_IN);
        FloatingMarket(market).setFixedCreditLimit(DEBT); // GOVERNOR (this contract holds it)
        vm.prank(eve);
        FloatingMarket(market).borrow(eve, type(uint256).max);
        assertEq(FloatingMarket(market).totalDebt(), DEBT);
    }

    function _appendJunior(address asset) internal returns (address junior) {
        uint256[] memory w = new uint256[](tranches.length + 1);
        for (uint256 i; i < tranches.length; ++i) {
            w[i] = 0;
        }
        w[tranches.length] = 1e27;
        vm.prank(eve);
        junior = registry.createTranche(market, asset, w);
    }

    function _exitAll(address tranche) internal returns (uint256 redeemed) {
        uint256 shares = Tranche(tranche).maxInstantRedeem(eve);
        if (shares == 0) return 0;
        vm.prank(eve);
        redeemed = Tranche(tranche).instantRedeem(shares, eve, eve);
    }

    // ── (d) USD coverage at the instant of the swap ───────────────────────────

    /// The author's path, re-derived: the senior only unlocks because the junior's USD value
    /// covers ceil(debt/(lt-buffer)). After the exit the waterfall still holds >= that USD and
    /// health >= lt/(lt-buffer) = 1.142857. cUSD holders' USD coverage ratio is unchanged.
    function test_verify_swapPreservesUsdCoverageRequirement() public {
        _singleWethMarketSizedAndDrawn();
        Tranche senior = Tranche(tranches[0]);
        assertEq(FloatingMarket(market).lockedValue(address(senior)), REQUIRED, "lock before = ceil(D/(lt-b))");

        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        address junior = _appendJunior(address(alt));
        _eveDeposits(junior, address(alt), 1_000_000e18);

        assertEq(FloatingMarket(market).lockedValue(address(senior)), 0, "junior carries the whole lock");
        assertEq(FloatingMarket(market).lockedValue(junior), REQUIRED, "same USD requirement, moved down");
        uint256 out = _exitAll(address(senior));
        assertEq(out, WETH_IN - DEAD_SHARES, "eve got her WETH back (less dead shares)");

        uint256 capitalAfter = FloatingMarket(market).totalCapital();
        emit log_named_uint("capital after swap (USD)", capitalAfter);
        emit log_named_uint("required (USD)          ", REQUIRED);
        emit log_named_uint("health after swap (ray) ", FloatingMarket(market).healthiness());
        assertGe(capitalAfter, REQUIRED, "waterfall never drops below D/(lt-buffer) in USD");
        assertGe(FloatingMarket(market).healthiness(), 1_142_857_142_857_142_857_142_857_142, "health >= lt/(lt-b)");
        // the junior is now exactly as locked as the senior was
        assertEq(
            Tranche(junior).totalSupply() - Tranche(junior).unlockedSupply(),
            REQUIRED, // 714,285.714... ALT shares at $1, quoted 1:1 while the vault is at par
            "junior locked in shares == USD requirement at $1"
        );
        // creditLimit = min(fixed, activeCapital*ltv) = min(500k, 1M*0.7) — the line is exactly full, no fresh credit
        emit log_named_uint("creditLimit after swap ", FloatingMarket(market).creditLimit());
    }

    /// A substitute short of the USD requirement leaves the senior partially locked by exactly
    /// the shortfall; nothing lets the senior exit more than the junior's USD value covers.
    function test_verify_underfundedJuniorLeavesSeniorLockedByTheShortfall() public {
        _singleWethMarketSizedAndDrawn();
        Tranche senior = Tranche(tranches[0]);

        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        address junior = _appendJunior(address(alt));
        _eveDeposits(junior, address(alt), 700_000e18); // $700k < $714,285.71

        uint256 shortfall = REQUIRED - 700_000e18; // 14,285.714285714285714286e18
        assertEq(FloatingMarket(market).lockedValue(address(senior)), shortfall, "senior locks only the shortfall");
        uint256 lockedShares = senior.totalSupply() - senior.unlockedSupply();
        emit log_named_uint("senior locked shares", lockedShares);
        assertGe(lockedShares, shortfall, "at $1 the locked shares cover the USD shortfall");

        _exitAll(address(senior));
        assertGe(FloatingMarket(market).totalCapital(), REQUIRED, "still >= D/(lt-buffer) after max exit");
        assertGe(FloatingMarket(market).healthiness(), 1e27);
    }

    /// A cheap substitute is valued at its oracle price: 1M ALT at $0.50 is $500k, so the senior
    /// keeps $214,285.71 locked. Quantity of the junior asset buys nothing; only USD does.
    function test_verify_cheapSubstituteIsValuedAtOraclePrice() public {
        _singleWethMarketSizedAndDrawn();
        Tranche senior = Tranche(tranches[0]);

        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 0.5e18);
        address junior = _appendJunior(address(alt));
        _eveDeposits(junior, address(alt), 1_000_000e18); // $500k

        assertEq(FloatingMarket(market).lockedValue(address(senior)), REQUIRED - 500_000e18);
        _exitAll(address(senior));
        assertGe(FloatingMarket(market).totalCapital(), REQUIRED);
        assertGe(FloatingMarket(market).healthiness(), 1e27);
    }

    // ── (a) is createTranche the enabling primitive? ──────────────────────────

    /// Same outcome with NO createTranche: the market is created with an empty ALT junior that
    /// GOVERNOR can see when it sizes the line. Sizing was never bound to what the tranches held.
    function test_verify_sameSwapWithoutCreateTranche_preexistingEmptyJunior() public {
        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(alt);
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e27;
        w[1] = 0.5e27;
        _eveMarket(assets, w);
        _eveDeposits(tranches[0], address(collateral), WETH_IN);
        assertEq(Tranche(tranches[1]).totalAssets(), 0, "ALT junior is empty when GOVERNOR sizes");

        FloatingMarket(market).setFixedCreditLimit(DEBT); // GOVERNOR sizes, sees [WETH: 1M, ALT: 0]
        vm.prank(eve);
        FloatingMarket(market).borrow(eve, type(uint256).max);

        _eveDeposits(tranches[1], address(alt), 1_000_000e18);
        assertEq(Tranche(tranches[0]).unlockedSupply(), Tranche(tranches[0]).totalSupply(), "senior WETH free");
        uint256 out = _exitAll(tranches[0]);
        assertEq(out, WETH_IN - DEAD_SHARES);
        assertGe(FloatingMarket(market).totalCapital(), REQUIRED);
        assertGe(FloatingMarket(market).healthiness(), 1e27);
    }

    /// Even a single-asset market lets the owner rotate collateral *within* the asset: any
    /// third party's deposit into the same tranche unlocks eve's shares pro rata. The finding's
    /// "GOVERNOR sized against eve's WETH" premise is not encoded anywhere.
    function test_verify_singleTrancheRotationWithinTheSameAsset() public {
        _singleWethMarketSizedAndDrawn();
        Tranche senior = Tranche(tranches[0]);
        address other = makeAddr("other-underwriter");
        uint64 depRole = accessManager.getTargetFunctionRole(address(senior), IERC4626.deposit.selector);
        vm.prank(eve); // eve's owner role administers the depositor role
        accessManager.grantRole(depRole, other, 0);
        collateral.mint(other, WETH_IN);
        vm.startPrank(other);
        collateral.approve(address(vault), WETH_IN);
        vault.deposit(address(collateral), WETH_IN, other);
        vault.setOperator(address(senior), true);
        senior.deposit(WETH_IN, other);
        vm.stopPrank();

        // 2M in the tranche, 714k locked: eve's 1M is fully redeemable
        assertGe(senior.maxInstantRedeem(eve), senior.balanceOf(eve));
        uint256 out = _exitAll(address(senior));
        assertEq(out, WETH_IN - DEAD_SHARES);
        assertGe(FloatingMarket(market).healthiness(), 1e27);
    }

    // ── (b) GOVERNOR's feed whitelist bounds the asset set; there is an event ──

    function test_verify_unpricedAssetCannotBeAppended_andCreateTrancheEmitsAsset() public {
        _singleWethMarketSizedAndDrawn();
        MockERC20 unpriced = new MockERC20("Nope", "NOPE", 18);
        uint256[] memory w = new uint256[](2);
        w[0] = 0;
        w[1] = 1e27;
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, address(unpriced)));
        registry.createTranche(market, address(unpriced), w);

        // GOVERNOR delisting the feed also closes the door, even though eve can still own markets
        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        oracle.setSource(address(alt), new IOracle.Sources[](0));
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IOracle.PriceError.selector, address(alt)));
        registry.createTranche(market, address(alt), w);

        // re-list: the append emits CreateTranche(market, tranche, asset, ownerRole, depositorRole)
        _setPrice(address(alt), 1e18);
        vm.expectEmit(true, false, false, false, address(registry));
        emit IRegistry.CreateTranche(market, address(0), address(alt), eveRole, 0);
        vm.prank(eve);
        registry.createTranche(market, address(alt), w);
    }

    // ── (c) the _setTranches health check is not the guard; lockedValue is ────

    /// The append itself changes nothing (empty junior): health identical before and after, so
    /// the `healthiness() >= 1e27` check in `_setTranches` neither helps nor hurts this path.
    function test_verify_setTranchesHealthCheckIsInertForAnEmptyAppend() public {
        _singleWethMarketSizedAndDrawn();
        uint256 hBefore = FloatingMarket(market).healthiness();
        uint256 lockBefore = FloatingMarket(market).lockedValue(tranches[0]);
        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        _appendJunior(address(alt));
        assertEq(FloatingMarket(market).healthiness(), hBefore, "append is health-neutral");
        assertEq(FloatingMarket(market).lockedValue(tranches[0]), lockBefore, "and lock-neutral until funded");
    }
}
