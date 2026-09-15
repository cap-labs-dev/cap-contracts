// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../../../../contracts/cap/Underwriter.sol";
import { IVault } from "../../../../../../contracts/interfaces/IVault.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// Fake that also answers the calls _report makes, so removeTranche succeeds on it.
contract PoliteDrain {
    function optIn() external { }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 0;
    }

    function claim(address) external pure returns (uint256) {
        return 0;
    }

    function pull(address vault, address from, address asset, address to) external returns (uint256 moved) {
        moved = IVault(vault).balanceOf(from, asset);
        IVault(vault).transferFrom(from, to, asset, moved);
    }
}

contract Verify_CuratorDrain is CapDeployer {
    Underwriter uw;
    address alice = makeAddr("alice");
    address thief = makeAddr("thief");

    function setUp() public {
        _deployCap();
        uw = _deployUnderwriter(); // production path: registry.createUnderwriter, curator == this
        _fundUnderwriter(address(uw), alice, 1_000e18);
    }

    /// A curator-controlled fake that stubs balanceOf/previewRedeem/claim is fully removable, so
    /// "irrevocable below ADMIN" only holds for a fake that reverts (or an EOA) -- not in general.
    function test_stubbedFakeIsRemovableAfterDrain() public {
        PoliteDrain d = new PoliteDrain();
        uw.addTranche(address(d));
        uint256 moved = d.pull(address(vault), address(uw), address(collateral), thief);
        assertEq(moved, 1_000e18);
        uw.removeTranche(address(d)); // does NOT revert
        assertFalse(vault.isOperator(address(uw), address(d)));
        assertEq(uw.totalAssets(), 0, "loss is unchanged by revocation");
    }

    /// An EOA (typo) never gets in: addTranche's optIn() call reverts on a no-code address, so
    /// the "typo'd address, irrevocable" scenario in the N3 trust-model table is unreachable.
    function test_eoaTypoRevertsAtAddTranche() public {
        address typo = makeAddr("typo");
        vm.expectRevert();
        uw.addTranche(typo);
        assertFalse(vault.isOperator(address(uw), typo));
    }

    /// Revoking the curator's operator role does not clear the Vault operator flag: only the
    /// underwriter itself can call vault.setOperator, and it only does so inside add/removeTranche.
    function test_roleRevocationDoesNotClearVaultOperatorFlag() public {
        PoliteDrain d = new PoliteDrain();
        uw.addTranche(address(d));
        uint64 role = registry.operatorRole(address(this));
        vm.prank(address(registry)); // REGISTRY is the role admin
        IAccessManager(address(accessManager)).revokeRole(role, address(this));
        vm.expectRevert();
        uw.removeTranche(address(d)); // curator no longer allowed
        assertTrue(vault.isOperator(address(uw), address(d)), "grant persists after role revocation");
        uint256 moved = d.pull(address(vault), address(uw), address(collateral), thief);
        assertEq(moved, 1_000e18, "fake still drains after the curator is fired");
    }
}
