// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { IERC7540AsyncRedeem } from "../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IERC7540Operator } from "../../../contracts/interfaces/IERC7540Operator.sol";
import { IERC7540Redeem } from "../../../contracts/interfaces/IERC7540Redeem.sol";
import { IERC7575 } from "../../../contracts/interfaces/IERC7575.sol";
import { IUnderwriter } from "../../../contracts/interfaces/IUnderwriter.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract UnderwriterUnitTest is BaseTest {
    /// @dev Stands in for the role the Registry allocates per underwriter and wires the entry
    /// points to. Its admin defaults to ADMIN, which this contract holds, so grants need no further
    /// wiring.
    uint64 internal constant DEPOSITOR_ROLE = 100;

    /// @dev Mirrors {DeadShares-SHARES}
    uint256 internal constant DEAD_SHARES = 1e3;

    Underwriter internal underwriter;
    MockERC20 internal collateral;

    /// @dev Assets the mocked vault reports as held for the underwriter
    uint256 internal vaultBalance;

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
                    (address(accessManager), address(this), "Underwriter", "UW", address(collateral), vault, stablecoin)
                )
            )
        );

        // the Registry does this on a real deployment: the allowlist is the membership of whichever
        // role the entry points are gated to
        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE);

        // addTranche and removeTranche toggle vault operator rights on the mocked vault
        vm.mockCall(vault, abi.encodeWithSignature("setOperator(address,bool)"), abi.encode(true));
        // and opt the vault into the tranche's vesting so it can earn what {report} later claims
        vm.mockCall(tranche, abi.encodeWithSignature("optIn()"), abi.encode());
        vm.mockCall(tranche, abi.encodeWithSignature("optOut()"), abi.encode());
        vm.mockCall(tranche, abi.encodeWithSignature("claim(address)", address(underwriter)), abi.encode(uint256(0)));
        vm.mockCall(tranche, abi.encodeWithSelector(IERC20.balanceOf.selector, address(underwriter)), abi.encode(0));
        vm.mockCall(tranche, abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(0));
    }

    /// @dev The gate is nothing but the AccessManager's answer for the gated selector, so this
    /// asks it the same question the {IERC4626-deposit} modifier does.
    function _mayDeposit(address account) internal view returns (bool allowed) {
        (allowed,) = accessManager.canCall(account, address(underwriter), IERC4626.deposit.selector);
    }

    function _depositorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IERC4626.mint.selector;
    }

    function test_emptyVaultQuotesMintAtParPlusTheSeed() public view {
        assertEq(underwriter.previewDeposit(1e18), 1e18 - DEAD_SHARES);
        assertEq(underwriter.previewMint(1e18 - DEAD_SHARES), 1e18);
    }

    function test_mintSeedsDeadShares() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);
        _mockVault();
        collateral.mint(supplier, 1e18);

        vm.startPrank(supplier);
        collateral.approve(address(underwriter), 1e18);
        uint256 assets = underwriter.mint(1e18 - DEAD_SHARES, supplier);
        vm.stopPrank();

        assertEq(assets, 1e18);
        assertEq(underwriter.balanceOf(DeadShares.HOLDER), DEAD_SHARES);
        assertEq(underwriter.balanceOf(supplier), 1e18 - DEAD_SHARES);
    }

    function test_supportsInterface() public view {
        assertTrue(underwriter.supportsInterface(type(IERC7540AsyncRedeem).interfaceId));
        assertTrue(underwriter.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(underwriter.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(underwriter.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(underwriter.supportsInterface(type(IERC4626).interfaceId));
        assertFalse(underwriter.supportsInterface(0xffffffff));
        assertFalse(underwriter.supportsInterface(0xce3bbe50), "not async deposit");
    }

    function test_initializedState() public view {
        assertEq(underwriter.asset(), address(collateral));
        assertEq(underwriter.vault(), vault);
        assertEq(underwriter.registry(), address(this));
        assertEq(underwriter.authority(), address(accessManager));
        assertEq(underwriter.totalSupply(), 0);
        assertEq(underwriter.stablecoin(), stablecoin);
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        underwriter.initialize(
            address(accessManager), address(this), "Underwriter", "UW", address(collateral), vault, stablecoin
        );
    }

    /// @dev Admission is membership of the role the entry points are gated to, so the gate is
    /// enforced by the AccessManager rather than by a list on the vault. A stranger holds no role
    /// admin over it.
    function test_depositorRole_strangerCannotAdmit() public {
        vm.prank(stranger);
        vm.expectRevert();
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        assertFalse(_mayDeposit(supplier), "and nobody was admitted");
    }

    function test_depositorRoleMembershipDrivesAdmission() public {
        assertFalse(_mayDeposit(supplier));
        _expectDepositRejected(supplier);

        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        assertTrue(_mayDeposit(supplier));
        _deposit(supplier, supplier);

        // revoking closes the vault to them again, which is the half a mapping-based list made
        // awkward to express through the role system at all
        accessManager.revokeRole(DEPOSITOR_ROLE, supplier);
        assertFalse(_mayDeposit(supplier));
        _expectDepositRejected(supplier);
    }

    /// @dev AccessManager reports the public role as held by every account, so gating the entry
    /// points to it opens the vault to all without needing a per-account grant.
    function test_publicRoleOnTheEntryPointsOpensTheVaultToEveryone() public {
        assertFalse(_mayDeposit(stranger), "curated to begin with");
        _expectDepositRejected(stranger);

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), type(uint64).max);

        assertTrue(_mayDeposit(stranger), "anyone may deposit");
        _deposit(stranger, stranger);
    }

    /// @dev {maxDeposit} is left at the ERC4626 default rather than gating the receiver. The
    /// restriction is on the caller, which a receiver-parameterised figure cannot express, so
    /// reporting a cap there would only be a cap on the wrong subject.
    function test_maxDepositIsUnrestrictedBecauseTheGateIsOnTheCaller() public view {
        assertFalse(_mayDeposit(stranger));
        assertEq(underwriter.maxDeposit(stranger), type(uint256).max);
        assertEq(underwriter.maxMint(stranger), type(uint256).max);
    }

    /// @dev Rewiring the gate swaps which role is consulted rather than editing a list, so the
    /// previous role's membership survives and pointing back restores it.
    function test_rewiringTheGateDoesNotDisturbTheOldRolesMembership() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);
        assertTrue(_mayDeposit(supplier));

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE + 1);
        assertFalse(_mayDeposit(supplier), "not a member of the new role");

        accessManager.setTargetFunctionRole(address(underwriter), _depositorSelectors(), DEPOSITOR_ROLE);
        assertTrue(_mayDeposit(supplier), "and the old allowlist came back intact");
    }

    /// @dev The gate is on the caller and nothing else. A non-member is stopped even when the
    /// receiver is admitted, and a member may direct the shares wherever they like, which is only
    /// honest about the fact that shares are transferable the instant they exist.
    function test_depositIsGatedOnTheCallerAndNotTheReceiver() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        collateral.mint(stranger, 1e18);
        vm.startPrank(stranger);
        collateral.approve(address(underwriter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        underwriter.deposit(1e18, supplier);
        vm.stopPrank();

        _deposit(supplier, stranger);
        assertGt(underwriter.balanceOf(stranger), 0, "an admitted caller may mint to anyone");
    }

    /// @dev Why the receiver is not gated as well. A grant carrying an execution delay is not
    /// authorized immediately: the caller has to schedule the call and let the delay run, and
    /// {AccessManagedUpgradeable-restricted} then clears it by consuming the scheduled operation.
    /// {IAccessManager-canCall}'s immediate flag stays false throughout, so a {maxDeposit} keyed to
    /// it would have reverted this deposit on the max for somebody the AccessManager had cleared.
    function test_delayedGrantCanStillDeposit() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 1 days);
        assertFalse(_mayDeposit(supplier), "not immediately authorized");

        collateral.mint(supplier, 1e18);
        vm.prank(supplier);
        collateral.approve(address(underwriter), 1e18);

        bytes memory call = abi.encodeCall(IERC4626.deposit, (1e18, supplier));
        vm.prank(supplier);
        accessManager.schedule(address(underwriter), call, 0);
        vm.warp(block.timestamp + 1 days);

        _mockVault();
        vm.prank(supplier);
        (bool ok,) = address(underwriter).call(call);

        assertTrue(ok, "the schedule clears the modifier");
        assertGt(underwriter.balanceOf(supplier), 0);
    }

    // ── dead shares ───────────────────────────────────────────────────────────

    function test_deadShares_firstDepositSeedsTheBurnAddress() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);
        _deposit(supplier, supplier);

        assertEq(underwriter.balanceOf(DeadShares.HOLDER), DEAD_SHARES, "the burn address holds them");
        assertEq(underwriter.totalSupply(), 1e18, "the whole first deposit, seed included");
        assertEq(underwriter.balanceOf(supplier), 1e18 - DEAD_SHARES, "the first depositor paid for it");

        // and only the first depositor pays
        accessManager.grantRole(DEPOSITOR_ROLE, stranger, 0);
        _deposit(stranger, stranger);
        assertEq(underwriter.balanceOf(DeadShares.HOLDER), DEAD_SHARES, "no second seeding");
        assertEq(underwriter.balanceOf(stranger), 1e18, "and nothing taken from the second");
    }

    /// @dev The wei-sized opening position an inflation attack starts from is refused rather than
    /// quietly rounding away, since a first deposit has to be able to cover the seed.
    function test_deadShares_firstDepositBelowTheSeedIsRejected() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);
        _mockVault();
        collateral.mint(supplier, DEAD_SHARES);

        vm.startPrank(supplier);
        collateral.approve(address(underwriter), DEAD_SHARES);
        vm.expectRevert(abi.encodeWithSelector(DeadShares.DepositBelowSeed.selector, DEAD_SHARES, DEAD_SHARES));
        underwriter.deposit(DEAD_SHARES, supplier);
        vm.stopPrank();
    }

    /// @dev Pricing the empty vault at par is what makes the seed work: a donation landing before
    /// anyone has deposited cannot set the rate for the depositor who arrives after it.
    function test_deadShares_donationBeforeTheFirstDepositCannotRoundItAway() public {
        accessManager.grantRole(DEPOSITOR_ROLE, supplier, 0);

        // the vault reports a balance it was never issued shares against
        vm.mockCall(vault, abi.encodeWithSignature("transferFrom(address,address,address,uint256)"), "");
        vm.mockCall(vault, abi.encodeWithSignature("balanceOf(address,address)"), abi.encode(uint256(100e18)));
        assertEq(underwriter.totalAssets(), 100e18, "donated while completely empty");
        assertEq(underwriter.totalSupply(), 0);

        collateral.mint(supplier, 1e18);
        vm.startPrank(supplier);
        collateral.approve(address(underwriter), 1e18);
        uint256 shares = underwriter.deposit(1e18, supplier);
        vm.stopPrank();

        assertEq(shares, 1e18 - DEAD_SHARES, "priced at par, so the donation did not round them away");
    }

    /// @dev A deposit pulls assets through the vault and prices itself off the balance held there.
    /// Both are mocked, with the balance tracked so a second deposit is priced off the first rather
    /// than against a vault that forgot it.
    function _mockVault() internal {
        vm.mockCall(vault, abi.encodeWithSignature("transferFrom(address,address,address,uint256)"), "");
        vm.mockCall(vault, abi.encodeWithSignature("balanceOf(address,address)"), abi.encode(vaultBalance));
    }

    function _deposit(address caller, address receiver) internal {
        _mockVault();
        collateral.mint(caller, 1e18);
        vm.startPrank(caller);
        collateral.approve(address(underwriter), 1e18);
        underwriter.deposit(1e18, receiver);
        vm.stopPrank();
        vaultBalance += 1e18;
        _mockVault();
    }

    function _expectDepositRejected(address caller) internal {
        collateral.mint(caller, 1e18);
        vm.startPrank(caller);
        collateral.approve(address(underwriter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        underwriter.deposit(1e18, caller);
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

    function test_remaining_zeroInitially() public view {
        assertEq(underwriter.remaining(), 0);
        assertEq(underwriter.vested(), 0);
        assertEq(underwriter.premiumPerSecond(), 0);
    }

    function test_vestingPeriod_isTwelveHours() public view {
        assertEq(underwriter.vestingPeriod(), 12 hours);
    }

    function test_claimable_zeroInitially() public view {
        assertEq(underwriter.claimable(supplier), 0);
    }

    function test_addTranche_optsTheVaultIntoTheTranche() public {
        vm.expectCall(tranche, abi.encodeWithSignature("optIn()"));
        underwriter.addTranche(tranche);
    }

    function test_report_foldsClaimedPremiumIntoTheRemainder() public {
        underwriter.addTranche(tranche);
        vm.mockCall(tranche, abi.encodeWithSignature("claim(address)", address(underwriter)), abi.encode(uint256(5e18)));

        vm.expectCall(tranche, abi.encodeWithSignature("claim(address)", address(underwriter)));
        underwriter.report(tranche);

        assertEq(underwriter.remaining(), 5e18);
        assertEq(underwriter.lastReported(), block.timestamp);
    }

    function test_removeTranche_reportsBeforeDeregistering() public {
        underwriter.addTranche(tranche);
        underwriter.setDefaultTranche(tranche);
        _openBook(1e18);

        vm.mockCall(tranche, abi.encodeWithSignature("claim(address)", address(underwriter)), abi.encode(uint256(2e18)));

        vm.expectCall(tranche, abi.encodeWithSignature("claim(address)", address(underwriter)));
        underwriter.removeTranche(tranche);

        assertEq(underwriter.remaining(), 2e18);
        assertEq(underwriter.defaultTranche(), address(0));
    }

    /// @dev deallocate remakes a book that allocate already opened. An airdropped vault with a
    /// huge convertToAssets must not be able to enter totalDebt through a refresh.
    function test_deallocate_doesNotOpenABookFromAnAirdrop() public {
        address dumped = makeAddr("airdroppedVault");
        vm.mockCall(dumped, abi.encodeWithSelector(IERC20.balanceOf.selector, address(underwriter)), abi.encode(1e18));
        vm.mockCall(dumped, abi.encodeWithSignature("instantUnlockedSupply()"), abi.encode(1e18));
        vm.mockCall(dumped, abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(1e30));

        uint256 book = underwriter.totalDebt();
        underwriter.deallocate(dumped, 0);

        assertEq(underwriter.totalDebt(), book);
        assertEq(underwriter.debt(dumped), 0);
    }

    /// @dev report is the same gate: claiming premium on a registered tranche does not book an
    /// airdrop that allocate never opened.
    function test_report_doesNotOpenABookFromAnAirdrop() public {
        underwriter.addTranche(tranche);
        vm.mockCall(tranche, abi.encodeWithSelector(IERC20.balanceOf.selector, address(underwriter)), abi.encode(1e18));
        vm.mockCall(tranche, abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(1e30));

        underwriter.report(tranche);

        assertEq(underwriter.debt(tranche), 0);
        assertEq(underwriter.totalDebt(), 0);
    }

    function _openBook(uint256 assets) internal {
        vm.mockCall(
            tranche,
            abi.encodeWithSignature("deposit(uint256,address)", assets, address(underwriter)),
            abi.encode(assets)
        );
        vm.mockCall(
            tranche, abi.encodeWithSelector(IERC20.balanceOf.selector, address(underwriter)), abi.encode(assets)
        );
        vm.mockCall(tranche, abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(assets));
        underwriter.allocate(tranche, assets);
    }
}
