// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../../test/shared/CapRoles.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// P14: what a single WHITELISTED third party can do end to end with no other cooperation.
contract P14_Whitelisted is CapDeployer {
    address eve = makeAddr("eve");
    uint64 eveRole;
    address market;
    address[] tranches;

    function setUp() public {
        _deployCap();
        accessManager.grantRole(CapRoles.WHITELISTED, eve, 0);

        // eve mints herself an operator role (admin = GOVERNOR, she cannot admin it, but she is a member)
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = eve;
        vm.prank(eve);
        eveRole = registry.createChildRoles(CapRoles.GOVERNOR, members)[0];

        // eve creates a market she owns, single tranche of the governor-priced collateral
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e27;
        vm.prank(eve);
        (market, tranches) = registry.createFloatingMarket(assets, weights, "Eve", eveRole);

        // eve is market owner: sets ltv to the max, names herself borrower
        vm.startPrank(eve);
        FloatingMarket(market).setLtv(capConfig.defaultLt - capConfig.defaultBuffer); // 0.7
        FloatingMarket(market).setBorrowerRole(eveRole);
        // depositor role of her tranche is administered by her owner role
        uint64 depRole = accessManager.getTargetFunctionRole(tranches[0], IERC4626.deposit.selector);
        accessManager.grantRole(depRole, eve, 0);
        vm.stopPrank();

        // eve posts her own collateral
        collateral.mint(eve, 1_000_000e18);
        vm.startPrank(eve);
        collateral.approve(address(vault), type(uint256).max);
        vault.deposit(address(collateral), 1_000_000e18, eve);
        vault.setOperator(tranches[0], true);
        Tranche(tranches[0]).deposit(1_000_000e18, eve);
        vm.stopPrank();
    }

    /// Claim 1: without GOVERNOR sizing the market, eve cannot borrow a single wei.
    function test_P14_noCreditUntilGovernorSetsLimit() public {
        assertEq(FloatingMarket(market).fixedCreditLimit(), 0, "fixedCreditLimit defaults to 0");
        assertEq(FloatingMarket(market).creditLimit(), 0);
        assertEq(FloatingMarket(market).variableCreditLimit(), 700_000e18, "variable limit is 1M * 0.7");
        vm.prank(eve);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        FloatingMarket(market).borrow(eve, 1e18);
    }

    /// Claim 2: once GOVERNOR sizes it, eve borrows the whole line against collateral only she controls,
    /// with no underwriter, no second party, and cUSD holders bear the credit risk.
    function test_P14_selfUnderwrittenLineAfterGovernorLimit() public {
        FloatingMarket(market).setFixedCreditLimit(500_000e18); // GOVERNOR
        vm.prank(eve);
        uint256 got = FloatingMarket(market).borrow(eve, type(uint256).max);
        assertEq(got, 500_000e18);
        assertEq(stablecoin.balanceOf(eve), 500_000e18);
        assertEq(stablecoin.creditBackedSupply(), 500_000e18);
        // healthy: 1M * 0.8 / 0.5M = 1.6
        assertEq(FloatingMarket(market).healthiness(), 1.6e27);
    }

    /// Claim 3: after GOVERNOR sized the line against WETH, eve appends a junior tranche in a different
    /// governor-priced asset, funds it, and the senior WETH becomes withdrawable while debt is out.
    function test_P14_ownerSwapsCollateralBasisAfterSizing() public {
        FloatingMarket(market).setFixedCreditLimit(500_000e18);
        vm.prank(eve);
        FloatingMarket(market).borrow(eve, type(uint256).max);

        Tranche senior = Tranche(tranches[0]);
        uint256 lockedBefore = senior.totalSupply() - senior.unlockedSupply();
        assertGt(lockedBefore, 0, "senior is locked while debt is out");

        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18); // any asset GOVERNOR has priced
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e27;
        w[1] = 0.5e27;
        vm.prank(eve);
        address junior = registry.createTranche(market, address(alt), w);

        uint64 depRole = accessManager.getTargetFunctionRole(junior, IERC4626.deposit.selector);
        vm.prank(eve);
        accessManager.grantRole(depRole, eve, 0);
        alt.mint(eve, 1_000_000e18);
        vm.startPrank(eve);
        alt.approve(address(vault), type(uint256).max);
        vault.deposit(address(alt), 1_000_000e18, eve);
        vault.setOperator(junior, true);
        Tranche(junior).deposit(1_000_000e18, eve);
        vm.stopPrank();

        // senior fully unlocked: the junior now carries the whole lock (debt/(lt-buffer) = 714k < 1M)
        assertEq(senior.unlockedSupply(), senior.totalSupply(), "senior WETH fully withdrawable");
        uint256 eveShares = senior.balanceOf(eve);
        vm.prank(eve);
        senior.instantRedeem(eveShares, eve, eve);
        // the 500k cUSD line GOVERNOR sized against WETH is now backed only by ALT
        assertLe(senior.totalAssets(), DEAD_SHARES, "only dead shares remain");
        assertApproxEqAbs(
            FloatingMarket(market).totalCapital(),
            1_000_000e18,
            DEAD_SHARES,
            "only ALT (plus dead-share dust) backs the line now"
        );
        assertGe(FloatingMarket(market).healthiness(), 1e27);
    }

    /// Claim 4: eve can make her tranche's deposit permissionless (PUBLIC_ROLE) — no guard on setDepositorRole.
    function test_P14_depositorRoleCanBePublic() public {
        vm.prank(eve);
        Tranche(tranches[0]).setDepositorRole(type(uint64).max);
        address rando = makeAddr("rando");
        collateral.mint(rando, 1e18);
        vm.startPrank(rando);
        collateral.approve(address(vault), 1e18);
        vault.deposit(address(collateral), 1e18, rando);
        vault.setOperator(tranches[0], true);
        Tranche(tranches[0]).deposit(1e18, rando);
        vm.stopPrank();
        assertGt(Tranche(tranches[0]).balanceOf(rando), 0);
    }
}
