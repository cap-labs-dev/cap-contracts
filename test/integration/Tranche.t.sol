// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

contract TrancheTest is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");
    Tranche internal tranche0;
    Tranche internal tranche1;
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        address marketAddr;
        address s;
        address j;
        (marketAddr, s, j) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);
        tranche0 = Tranche(s);
        tranche1 = Tranche(j);
    }

    function test_initializedState() public view {
        assertEq(tranche0.asset(), address(collateral));
        assertEq(tranche0.authority(), address(accessManager));
        assertEq(tranche0.totalAssets(), 0);
        assertEq(tranche0.totalSupply(), 0);
        assertEq(tranche0.market(), address(market));
    }

    function test_supportsInterface() public view {
        assertTrue(tranche0.supportsInterface(type(ITranche).interfaceId));
        assertFalse(tranche0.supportsInterface(0xffffffff));
    }

    function test_setWhitelist_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        tranche0.setWhitelist(supplier, true);
    }

    function test_setWhitelist_togglesAndAffectsMaxDeposit() public {
        assertFalse(tranche0.whitelisted(supplier));
        assertEq(tranche0.maxDeposit(supplier), 0);
        assertEq(tranche0.maxMint(supplier), 0);

        tranche0.setWhitelist(supplier, true);

        assertTrue(tranche0.whitelisted(supplier));
        assertEq(tranche0.maxDeposit(supplier), type(uint256).max);
        assertEq(tranche0.maxMint(supplier), type(uint256).max);

        tranche0.setWhitelist(supplier, false);
        assertFalse(tranche0.whitelisted(supplier));
        assertEq(tranche0.maxDeposit(supplier), 0);
    }

    function test_slash_onlyMarket() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        tranche0.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(tranche0.unlockedSupply(), 0);
    }

    function test_tranchesAreDistinct() public view {
        assertTrue(address(tranche0) != address(tranche1));
        assertEq(tranche1.asset(), address(collateral));
    }

    function test_deposit_requestRedeem_redeem_roundtrip() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        assertEq(tranche0.totalSupply(), 100e18);
        assertEq(tranche0.balanceOf(supplier), 100e18);
        assertEq(tranche0.unlockedSupply(), 100e18);

        vm.startPrank(supplier);
        uint256 id = tranche0.requestRedeem(100e18, supplier, supplier);
        assertEq(tranche0.claimableRedeemRequest(id, supplier), 100e18);
        uint256 assets = tranche0.redeem(id, 100e18, supplier, supplier);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(tranche0.totalSupply(), 0);
        assertEq(vault.balanceOf(supplier, address(collateral)), 100e18);
    }
}
