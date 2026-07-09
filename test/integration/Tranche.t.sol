// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "./CapDeployer.sol";

contract TrancheTest is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");
    uint64 internal managerId = MANAGER_ROLE;
    Tranche internal senior;
    Tranche internal junior;
    Market internal market;

    function setUp() public {
        _deployCap();
        address[] memory borrowers = new address[](0);
        address marketAddr;
        address s;
        address j;
        (marketAddr, s, j) = _createMarket("Market A", borrowers, managerId);
        market = Market(marketAddr);
        senior = Tranche(s);
        junior = Tranche(j);
    }

    function test_initializedState() public view {
        assertEq(senior.asset(), address(collateral));
        assertEq(senior.authority(), address(accessManager));
        assertEq(senior.totalAssets(), 0);
        assertEq(senior.totalSupply(), 0);
        assertEq(senior.market(), address(market));
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

    function test_slash_onlyMarket() public {
        vm.prank(stranger);
        vm.expectRevert(ITranche.Unauthorized.selector);
        senior.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(senior.unlockedSupply(), 0);
    }

    function test_updateIrm_callable() public {
        senior.updateIrm();
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
