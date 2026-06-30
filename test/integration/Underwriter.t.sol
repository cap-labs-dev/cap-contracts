// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "./CapDeployer.sol";

contract UnderwriterTest is CapDeployer {
    address internal manager = makeAddr("manager");
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");

    Underwriter internal senior;
    Underwriter internal junior;
    bytes32 internal marketId;

    function setUp() public {
        _deployCap();
        address[] memory borrowers = new address[](0);
        address s;
        address j;
        (marketId, s, j) = _createMarket("Market A", manager, borrowers);
        senior = Underwriter(s);
        junior = Underwriter(j);
    }

    function test_initializedState() public view {
        assertEq(senior.asset(), address(collateral));
        assertEq(senior.owner(), manager);
        assertEq(senior.totalAssets(), 0);
        assertEq(senior.totalSupply(), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(senior.supportsInterface(type(IUnderwriter).interfaceId));
        // an unknown id short-circuits into super.supportsInterface (which returns false)
        assertFalse(senior.supportsInterface(0xffffffff));
    }

    function test_setWhitelist_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        senior.setWhitelist(supplier, true);
    }

    function test_setWhitelist_togglesAndAffectsMaxDeposit() public {
        assertFalse(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), 0);
        assertEq(senior.maxMint(supplier), 0);

        vm.prank(manager);
        senior.setWhitelist(supplier, true);

        assertTrue(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), type(uint256).max);
        assertEq(senior.maxMint(supplier), type(uint256).max);

        vm.prank(manager);
        senior.setWhitelist(supplier, false);
        assertFalse(senior.whitelisted(supplier));
        assertEq(senior.maxDeposit(supplier), 0);
    }

    function test_slash_onlyLender() public {
        // only the Lender may slash; anyone else is rejected at the auth check
        vm.prank(stranger);
        vm.expectRevert(IUnderwriter.Unauthorized.selector);
        senior.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(senior.unlockedSupply(), 0);
    }

    function test_updateIRM_callable() public {
        // permissionless poke of the market interest rate model; must not revert
        senior.updateIRM();
    }

    function test_tranchesAreDistinct() public view {
        assertTrue(address(senior) != address(junior));
        assertEq(junior.asset(), address(collateral));
    }

    function test_deposit_requestRedeem_redeem_roundtrip() public {
        _fundUnderwriter(address(senior), manager, supplier, 100e18);
        assertEq(senior.totalSupply(), 100e18);
        assertEq(senior.balanceOf(supplier), 100e18);
        // no debt -> every share is unlocked
        assertEq(senior.unlockedSupply(), 100e18);

        vm.startPrank(supplier);
        uint256 id = senior.requestRedeem(100e18, supplier, supplier);
        assertEq(senior.claimableRedeemRequest(id, supplier), 100e18);
        uint256 assets = senior.redeem(id, 100e18, supplier, supplier);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(senior.totalSupply(), 0);
        // assets are returned to the supplier's vault (ERC6909) balance
        assertEq(vault.balanceOf(supplier, address(collateral)), 100e18);
    }
}
