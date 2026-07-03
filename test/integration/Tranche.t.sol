// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "./CapDeployer.sol";

contract TrancheTest is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");

    Tranche internal senior;
    Tranche internal junior;
    bytes32 internal marketId;

    function setUp() public {
        _deployCap();
        address[] memory borrowers = new address[](0);
        address s;
        address j;
        (marketId, s, j) = _createMarket("Market A", borrowers);
        senior = Tranche(s);
        junior = Tranche(j);
    }

    function test_initializedState() public view {
        assertEq(senior.asset(), address(collateral));
        assertEq(senior.authority(), address(accessManager));
        assertEq(senior.totalAssets(), 0);
        assertEq(senior.totalSupply(), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(senior.supportsInterface(type(ITranche).interfaceId));
        assertFalse(senior.supportsInterface(0xffffffff));
    }

    function test_setWhitelist_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        senior.setWhitelist(supplier, true);
    }

    function test_setWhitelist_togglesAndAffectsMaxDeposit() public {
        assertFalse(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), 0);
        assertEq(senior.maxMint(supplier), 0);

        senior.setWhitelist(supplier, true);

        assertTrue(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), type(uint256).max);
        assertEq(senior.maxMint(supplier), type(uint256).max);

        senior.setWhitelist(supplier, false);
        assertFalse(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), 0);
    }

    function test_slash_onlyLender() public {
        vm.prank(stranger);
        vm.expectRevert(ITranche.Unauthorized.selector);
        senior.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(senior.unlockedSupply(), 0);
    }

    function test_updateIRM_callable() public {
        senior.updateIRM();
    }

    function test_tranchesAreDistinct() public view {
        assertTrue(address(senior) != address(junior));
        assertEq(junior.asset(), address(collateral));
    }

    function test_deposit_requestRedeem_redeem_roundtrip() public {
        _fundTranche(address(senior), supplier, 100e18);
        assertEq(senior.totalSupply(), 100e18);
        assertEq(senior.balanceOf(supplier), 100e18);
        assertEq(senior.unlockedSupply(), 100e18);

        vm.startPrank(supplier);
        uint256 id = senior.requestRedeem(100e18, supplier, supplier);
        assertEq(senior.claimableRedeemRequest(id, supplier), 100e18);
        uint256 assets = senior.redeem(id, 100e18, supplier, supplier);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(senior.totalSupply(), 0);
        assertEq(vault.balanceOf(supplier, address(collateral)), 100e18);
    }
}
