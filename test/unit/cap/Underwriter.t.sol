// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../contracts/interfaces/IUnderwriter.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Minimal Lender stand-in: toggles tranche registration and returns a fixed tranche reward.
contract MockLender {
    mapping(address => bool) internal _tranches;
    uint256 internal _reward;

    function setTranche(address tranche, bool ok) external {
        _tranches[tranche] = ok;
    }

    function setReward(uint256 reward) external {
        _reward = reward;
    }

    function isTranche(address tranche) external view returns (bool) {
        return _tranches[tranche];
    }

    function claimTrancheReward(address, address) external view returns (uint256) {
        return _reward;
    }
}

/// @notice Unit tests for the Underwriter contract in isolation with mocked dependencies.
contract UnderwriterUnitTest is BaseTest {
    Underwriter internal underwriter;
    MockLender internal lender;
    MockERC20 internal collateral;

    address internal vault = makeAddr("vault");
    address internal tranche = makeAddr("tranche");
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");
    address internal rewardToken = makeAddr("rewardToken");

    function setUp() public {
        _setUpAccessManager();
        lender = new MockLender();
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        Underwriter impl = new Underwriter();
        underwriter = Underwriter(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Underwriter.initialize,
                    (
                        address(accessManager),
                        "Underwriter",
                        "UW",
                        address(collateral),
                        vault,
                        address(lender),
                        address(rewardToken)
                    )
                )
            )
        );
    }

    // --- init / upgrade ---

    function test_initializedState() public view {
        assertEq(underwriter.asset(), address(collateral));
        assertEq(underwriter.vault(), vault);
        assertEq(underwriter.lender(), address(lender));
        assertEq(underwriter.authority(), address(accessManager));
        assertEq(underwriter.totalSupply(), 0);
        assertEq(underwriter.rewardToken(), address(rewardToken));
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        underwriter.initialize(
            address(accessManager),
            "Underwriter",
            "UW",
            address(collateral),
            vault,
            address(lender),
            address(rewardToken)
        );
    }

    function test_upgrade_authorized() public {
        Underwriter newImpl = new Underwriter();
        UUPSUpgradeable(address(underwriter)).upgradeToAndCall(address(newImpl), "");
        assertEq(underwriter.lender(), address(lender));
    }

    function test_upgrade_unauthorized_reverts() public {
        Underwriter newImpl = new Underwriter();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(underwriter)).upgradeToAndCall(address(newImpl), "");
    }

    // --- whitelist ---

    function test_whitelist_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.whitelist(supplier, true);
    }

    function test_whitelist_togglesAndAffectsMaxDeposit() public {
        assertFalse(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), 0);
        assertEq(underwriter.maxMint(supplier), 0);

        underwriter.whitelist(supplier, true);

        assertTrue(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), type(uint256).max);
        assertEq(underwriter.maxMint(supplier), type(uint256).max);

        underwriter.whitelist(supplier, false);
        assertFalse(underwriter.whitelisted(supplier));
        assertEq(underwriter.maxDeposit(supplier), 0);
    }

    // --- allocation auth + invalid tranche guards ---

    function test_allocate_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.allocate(tranche, 1e18);
    }

    function test_allocate_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.allocate(tranche, 1e18);
    }

    function test_requestDeallocate_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.requestDeallocate(tranche, 1e18);
    }

    function test_deallocate_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.deallocate(tranche, 1e18);
    }

    function test_deallocateWithRequest_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.deallocate(tranche, 0, 1e18);
    }

    function test_report_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.report(tranche);
    }

    // --- default tranche ---

    function test_setDefaultTranche_onlyAuthority() public {
        lender.setTranche(tranche, true);
        vm.prank(stranger);
        vm.expectRevert();
        underwriter.setDefaultTranche(tranche);
    }

    function test_setDefaultTranche_invalidTranche_reverts() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.setDefaultTranche(tranche);
    }

    function test_setDefaultTranche_valid_emits() public {
        lender.setTranche(tranche, true);
        vm.expectEmit(false, false, false, true);
        emit IUnderwriter.SetDefaultTranche(tranche);
        underwriter.setDefaultTranche(tranche);
    }

    // --- ERC4626 views ---

    function test_totalAssets_isVaultBalancePlusDebt() public {
        vm.mockCall(
            vault,
            abi.encodeWithSignature("balanceOf(address,address)", address(underwriter), address(collateral)),
            abi.encode(500e18)
        );
        // no debt allocated yet, so totalAssets == vault custody balance
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

    // --- reward views (empty state) ---

    function test_vestedReward_zeroInitially() public view {
        assertEq(underwriter.vestedReward(), 0);
    }

    function test_vestingEnd_isDefaultVestingPeriod() public view {
        // initialize() sets a default vestingPeriod of 6 hours and lastReported stays 0
        assertEq(underwriter.vestingEnd(), 6 hours);
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
        assertEq(underwriter.vestingEnd(), 1 days);
    }

    function test_claimableReward_zeroInitially() public view {
        assertEq(underwriter.claimableReward(supplier), 0);
    }
}
