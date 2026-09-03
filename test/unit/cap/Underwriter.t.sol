// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../contracts/interfaces/IUnderwriter.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract UnderwriterUnitTest is BaseTest {
    /// @dev Stands in for the role the Registry allocates per underwriter and wires the entry
    /// points to. Its admin defaults to ADMIN, which this contract holds, so grants need no further
    /// wiring.
    uint64 internal constant DEPOSITOR_ROLE = 100;

    Underwriter internal underwriter;
    MockERC20 internal collateral;

    address internal vault = makeAddr("vault");
    address internal tranche = makeAddr("tranche");
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");
    address internal stablecoin = makeAddr("stablecoin");

    function setUp() public {
        _setUpAccessManager();
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        Underwriter impl = new Underwriter();
        underwriter = Underwriter(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Underwriter.initialize,
                    (address(accessManager), "Underwriter", "UW", address(collateral), vault, stablecoin)
                )
            )
        );

        // the Registry does this on a real deployment: the allowlist is the membership of whichever
        // role the entry points are gated to
        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE);

        // addTranche and removeTranche toggle vault operator rights on the mocked vault
        vm.mockCall(vault, abi.encodeWithSignature("setOperator(address,bool)"), abi.encode(true));
    }

    function _depositorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IERC4626.mint.selector;
    }

    function test_initializedState() public view {
        assertEq(underwriter.asset(), address(collateral));
        assertEq(underwriter.vault(), vault);
        assertEq(underwriter.authority(), address(accessManager));
        assertEq(underwriter.totalSupply(), 0);
        assertEq(underwriter.stablecoin(), stablecoin);
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        underwriter.initialize(address(accessManager), "Underwriter", "UW", address(collateral), vault, stablecoin);
    }

    /// @dev Admission is membership of the role the entry points are gated to, so the gate is
    /// enforced by the AccessManager rather than by a list on the vault. A stranger holds no role
    /// admin over it.
    function test_depositorRole_strangerCannotAdmit() public {
        vm.prank(stranger);
        vm.expectRevert();
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        assertFalse(underwriter.whitelisted(supplier), "and nobody was admitted");
    }

    function test_depositorRoleMembershipDrivesMaxDeposit() public {
        assertFalse(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), 0);
        assertEq(underwriter.maxMint(supplier), 0);

        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        assertTrue(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), type(uint256).max);
        assertEq(underwriter.maxMint(supplier), type(uint256).max);

        // revoking closes the vault to them again, which is the half a mapping-based list made
        // awkward to express through the role system at all
        accessManager.revokeRole(DEPOSITOR_ROLE, supplier);
        assertFalse(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), 0);
    }

    /// @dev AccessManager reports the public role as held by every account, so gating the entry
    /// points to it opens the vault to all without needing a per-account grant.
    function test_publicRoleOnTheEntryPointsOpensTheVaultToEveryone() public {
        assertFalse(underwriter.whitelisted(stranger), "curated to begin with");

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), type(uint64).max);

        assertTrue(underwriter.whitelisted(stranger), "anyone may deposit");
        assertEq(underwriter.maxDeposit(stranger), type(uint256).max);
    }

    /// @dev Rewiring the gate swaps which role is consulted rather than editing a list, so the
    /// previous role's membership survives and pointing back restores it.
    function test_rewiringTheGateDoesNotDisturbTheOldRolesMembership() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);
        assertTrue(underwriter.whitelisted(supplier));

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE + 1);
        assertFalse(underwriter.whitelisted(supplier), "not a member of the new role");

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE);
        assertTrue(underwriter.whitelisted(supplier), "and the old allowlist came back intact");
    }

    /// @dev The gate is on the caller, which a receiver-parameterised {maxDeposit} cannot express.
    /// A member depositing for a non-member is stopped by the max, a non-member depositing at all is
    /// stopped by the modifier, so both subjects have to be admitted.
    function test_depositIsGatedOnTheCallerNotOnlyTheReceiver() public {
        collateral.mint(stranger, 1e18);
        vm.startPrank(stranger);
        collateral.approve(address(underwriter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        underwriter.deposit(1e18, supplier);
        vm.stopPrank();
    }

    function test_allocate_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.allocate(tranche, 1e18);
    }

    function test_allocate_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.allocate(tranche, 1e18);
    }

    function test_report_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.report(tranche);
    }

    function test_setDefaultTranche_onlyAuthority() public {
        underwriter.addTranche(tranche);
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.setDefaultTranche(tranche);
    }

    function test_setDefaultTranche_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.setDefaultTranche(tranche);
    }

    function test_setDefaultTranche_valid_emits() public {
        underwriter.addTranche(tranche);
        vm.expectEmit(false, false, false, true);
        emit IUnderwriter.SetDefaultTranche(tranche);
        underwriter.setDefaultTranche(tranche);
    }

    function test_totalAssets_isVaultBalancePlusDebt() public {
        vm.mockCall(
            vault,
            abi.encodeWithSignature("balanceOf(address,address)", address(underwriter), address(collateral)),
            abi.encode(500e18)
        );
        assertEq(underwriter.totalAssets(), 500e18);
    }

    function test_unlockedSupply_zeroWithoutVaultBalance() public {
        vm.mockCall(
            vault,
            abi.encodeWithSignature("balanceOf(address,address)", address(underwriter), address(collateral)),
            abi.encode(0)
        );
        assertEq(underwriter.unlockedSupply(), 0);
    }

    function test_vestedReward_zeroInitially() public view {
        assertEq(underwriter.vestedReward(), 0);
    }

    /// @dev The schedule is anchored at deployment, so an empty epoch ends one default period out.
    /// This used to read a bare `6 hours`, which held only because the anchor sat uninitialised at
    /// zero and put the epoch back at the unix epoch.
    function test_vestingEnd_isDefaultVestingPeriod() public view {
        assertEq(underwriter.vestingEnd(), block.timestamp + 6 hours);
    }

    function test_setVestingPeriod_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.setVestingPeriod(1 days);
    }

    function test_setVestingPeriod_zero_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidVestingPeriod.selector);
        underwriter.setVestingPeriod(0);
    }

    function test_setVestingPeriod_updatesVestingEnd() public {
        underwriter.setVestingPeriod(1 days);
        assertEq(underwriter.vestingEnd(), block.timestamp + 1 days);
    }

    function test_claimable_zeroInitially() public view {
        assertEq(underwriter.claimable(supplier), 0);
    }
}
