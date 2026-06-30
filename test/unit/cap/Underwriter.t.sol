// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../utils/CapDeployer.sol";

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

    function test_slash_onlyVault() public {
        // anyone other than the vault is rejected at the auth check
        vm.prank(stranger);
        vm.expectRevert(IUnderwriter.Unauthorized.selector);
        senior.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(senior.unlockedSupply(), 0);
    }

    function test_tranchesAreDistinct() public view {
        assertTrue(address(senior) != address(junior));
        assertEq(junior.asset(), address(collateral));
    }
}
