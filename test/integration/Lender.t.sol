// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Lender } from "../../contracts/cap/Lender.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { MockOracle } from "../shared/mocks/MockOracle.sol";
import { CapDeployer } from "./CapDeployer.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract LenderTest is CapDeployer {
    address internal manager = makeAddr("manager");
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployCap();
    }

    function _borrowers() internal view returns (address[] memory b) {
        b = new address[](1);
        b[0] = borrower;
    }

    // --- admin setters ---

    function test_setBorrowCap_onlyAuthority() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert();
        lender.setBorrowCap(marketId, 1e18);
    }

    function test_setBorrowCap_effect() public {
        bytes32 marketId = _market();
        lender.setBorrowCap(marketId, 123e18);
        assertEq(lender.borrowCap(marketId), 123e18);
    }

    function test_setOracle_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setOracle(address(0xdead));
    }

    function test_setTargetHealth_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setTargetHealth(1.2e27);
    }

    // --- market creation ---

    function test_createMarket_returnsNonZeroIdAndTranches() public {
        (bytes32 marketId, address senior, address junior) = _createMarket("Market A", manager, _borrowers());

        // marketId is the keccak of the market params (shadow-bug fix => non-zero, deterministic)
        assertEq(marketId, keccak256(abi.encode("Market A", "Market A", address(collateral), manager)));
        assertTrue(senior != address(0));
        assertTrue(junior != address(0));
        assertTrue(senior != junior);

        assertEq(Underwriter(senior).asset(), address(collateral));
        assertEq(Underwriter(senior).owner(), manager);
        assertEq(Underwriter(junior).owner(), manager);
    }

    function test_createMarket_duplicate_reverts() public {
        _createMarket("Market A", manager, _borrowers());
        vm.expectRevert(ILender.MarketAlreadyExists.selector);
        _createMarket("Market A", manager, _borrowers());
    }

    function test_createMarket_invalidLtv_reverts() public {
        // ltv + buffer must be <= lt; here ltv close to lt with buffer pushes over
        address[] memory b = _borrowers();
        vm.expectRevert(ILender.InvalidLtv.selector);
        lender.createMarket("Bad", "Bad", address(collateral), manager, 0.75e27, b); // 0.75 + 0.1 > 0.8
    }

    function test_setLtv_onlyManager() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.setLtv(marketId, 0.4e27);

        vm.prank(manager);
        lender.setLtv(marketId, 0.4e27);
    }

    function test_addRemoveBorrower_onlyManager() public {
        bytes32 marketId = _market();
        vm.prank(manager);
        lender.addBorrower(marketId, stranger);
        vm.prank(manager);
        lender.removeBorrower(marketId, stranger);
    }

    function test_addBorrower_unauthorized_reverts() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.addBorrower(marketId, stranger);
    }

    function test_removeBorrower_unauthorized_reverts() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.removeBorrower(marketId, borrower);
    }

    function test_createMarket_duplicateBorrower_reverts() public {
        address[] memory dup = new address[](2);
        dup[0] = borrower;
        dup[1] = borrower;
        vm.expectRevert(ILender.InvalidBorrower.selector);
        lender.createMarket("Dup", "Dup", address(collateral), manager, DEFAULT_LTV, dup);
    }

    function test_setManager_transfersControl() public {
        bytes32 marketId = _market();
        address newManager = makeAddr("newManager");

        vm.prank(manager);
        lender.setManager(marketId, newManager);

        // the new manager can now manage the market
        vm.prank(newManager);
        lender.setLtv(marketId, 0.4e27);

        // the old manager can no longer manage it
        vm.prank(manager);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.setLtv(marketId, 0.3e27);
    }

    function test_setManager_zero_reverts() public {
        bytes32 marketId = _market();
        vm.prank(manager);
        vm.expectRevert(ILender.InvalidManager.selector);
        lender.setManager(marketId, address(0));
    }

    function test_setManager_unauthorized_reverts() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.setManager(marketId, stranger);
    }

    function test_setLtv_invalid_reverts() public {
        bytes32 marketId = _market();
        // ltv + buffer (0.1) must be <= lt (0.8); 0.75 + 0.1 > 0.8
        vm.prank(manager);
        vm.expectRevert(ILender.InvalidLtv.selector);
        lender.setLtv(marketId, 0.75e27);
    }

    function test_setBuffer_and_setLt_success() public {
        bytes32 marketId = _market();
        lender.setBuffer(marketId, 0.2e27);
        lender.setLt(marketId, 0.85e27);
    }

    function test_setOracle_effect() public {
        bytes32 marketId = _market();
        MockOracle newOracle = new MockOracle();
        newOracle.setPrice(address(collateral), 2e27);

        lender.setOracle(address(newOracle));
        assertEq(lender.getPrice(marketId), 2e27);
    }

    function test_setMultiplier_invalid_reverts() public {
        bytes32 marketId = _market();
        vm.expectRevert(ILender.InvalidMultiplier.selector);
        lender.setMultiplier(marketId, 11e27); // > max (10e27)
    }

    function test_setMultiplier_success() public {
        bytes32 marketId = _market();
        lender.setMultiplier(marketId, 2e27);
    }

    function test_setInterestType_onlyAuthority() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert();
        lender.setInterestType(marketId, false);
    }

    function test_setInterestType_success() public {
        bytes32 marketId = _market();
        lender.setInterestType(marketId, false);
    }

    function test_setDefaultBuffer_setDefaultLt_setLimits_success() public {
        lender.setDefaultBuffer(0.15e27);
        lender.setDefaultLt(0.82e27);
        lender.setMultiplierLimits(0, 20e27);
        lender.setBonusConfig(0.9e27, 0.03e27, 0.2e27);
        lender.setTargetHealth(1.2e27);
    }

    function test_upgrade_authorized() public {
        Lender newImpl = new Lender();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
        bytes32 marketId = _market();
        assertEq(lender.getPrice(marketId), 1e27); // still functional
    }

    function test_upgrade_unauthorized_reverts() public {
        Lender newImpl = new Lender();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
    }

    // NOTE: end-to-end borrow/repay/liquidate flows live in LendingFlow.t.sol and RewardRouting.t.sol.

    // helper: a default market
    function _market() internal returns (bytes32 marketId) {
        (marketId,,) = _createMarket("Market A", manager, _borrowers());
    }
}
