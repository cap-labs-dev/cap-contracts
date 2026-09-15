// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// Round-3 port of round-2 R2-M1 (verify/R2-MED-OWNER-SETTRANCHES). HEAD: `setTranches` is
/// REGISTRY-only (Registry.sol:435-437); the owner keeps `setTrancheWeights` (BaseMarket.sol:119-127,
/// same length, same order) and `Registry.createTranche` (append only, :177-199). Membership and
/// order of the slash loop are no longer owner-controlled. Residual: weight 0 is accepted.
contract R2_M1_OwnerSetTranches is CapDeployer {
    MarketBundle b;
    address owner = makeAddr("owner-only");
    address senior = makeAddr("seniorLP");
    address junior = makeAddr("juniorLP");

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        accessManager.grantRole(_operatorRoleOf(defaultMarketOwner), owner, 0);
        _fundTranche(b.tranche0Addr, senior, 1_000e18);
        _fundTranche(b.tranche1Addr, junior, 600e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max); // 800
        assertEq(b.market.totalDebt(), 800e18);
    }

    function test_ownerCannotStripOrReorder() public {
        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 1e27 });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        b.market.setTranches(only);

        IBaseMarket.Tranche[] memory swapped = new IBaseMarket.Tranche[](2);
        swapped[0] = IBaseMarket.Tranche({ tranche: b.tranche1Addr, weight: 0.95e27 });
        swapped[1] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 0.05e27 });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        b.market.setTranches(swapped);

        uint256[] memory one = new uint256[](1);
        one[0] = 1e27;
        vm.prank(owner);
        vm.expectRevert(IBaseMarket.InvalidMarket.selector);
        b.market.setTrancheWeights(one);

        IBaseMarket.Tranche[] memory ts = b.market.tranches();
        assertEq(ts.length, 2);
        assertEq(ts[0].tranche, b.tranche0Addr);
        assertEq(ts[1].tranche, b.tranche1Addr);
        assertGt(b.tranche0.unlockedSupply(), 0, "senior keeps its buffer");
    }

    function test_noProtocolRoleCanStripEither() public {
        address guardian = makeAddr("guardian");
        address governor = makeAddr("governor");
        (bool g1,) = accessManager.canCall(guardian, b.marketAddr, IBaseMarket.setTranches.selector);
        (bool g2,) = accessManager.canCall(governor, b.marketAddr, IBaseMarket.setTranches.selector);
        (bool reg,) = accessManager.canCall(address(registry), b.marketAddr, IBaseMarket.setTranches.selector);
        assertFalse(g1);
        assertFalse(g2);
        assertTrue(reg, "only the Registry, which exposes append-only createTranche");
    }

    function test_createTrancheAppendsBelowExistingJunior() public {
        uint256[] memory w = new uint256[](3);
        w[0] = 0.9e27;
        w[1] = 0.05e27;
        w[2] = 0.05e27;
        vm.prank(owner);
        address t2 = registry.createTranche(b.marketAddr, address(collateral), w);
        IBaseMarket.Tranche[] memory ts = b.market.tranches();
        assertEq(ts.length, 3);
        assertEq(ts[0].tranche, b.tranche0Addr, "senior unchanged");
        assertEq(ts[1].tranche, b.tranche1Addr, "junior unchanged");
        assertEq(ts[2].tranche, t2, "new tranche is most junior");
    }

    /// Residual (L-21 family): the owner may set a funded, locked tranche's weight to 0, cutting
    /// its premium to nothing while it stays first-loss and locked by the debt.
    function test_residual_ownerZeroesLockedJuniorWeight() public {
        uint256[] memory w = new uint256[](2);
        w[0] = 1e27;
        w[1] = 0;
        vm.prank(owner);
        b.market.setTrancheWeights(w);
        assertEq(b.tranche1.unlockedSupply(), 0, "junior fully locked by the debt");
        uint256 before = stablecoin.balanceOf(b.tranche1Addr);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 got = stablecoin.balanceOf(b.tranche1Addr) - before;
        emit log_named_uint("junior premium over 30d at weight 0", got);
        emit log_named_uint("senior premium over 30d", stablecoin.balanceOf(b.tranche0Addr));
        assertGt(got, 0, "a locked first-loss tranche must keep a nonzero premium weight");
    }
}
