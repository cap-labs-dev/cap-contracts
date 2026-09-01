// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { IUnderwriter } from "../../../contracts/interfaces/IUnderwriter.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";

contract UnderwriterUnitTest is BaseTest {
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

    function test_vestingEnd_isDefaultVestingPeriod() public view {
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

    function test_claimable_zeroInitially() public view {
        assertEq(underwriter.claimable(supplier), 0);
    }
}
