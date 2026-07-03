// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Lender } from "../../contracts/cap/Lender.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { MockOracle } from "../shared/mocks/MockOracle.sol";
import { CapDeployer } from "./CapDeployer.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract LenderTest is CapDeployer {
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
        (bytes32 marketId, address senior, address junior) = _createMarket("Market A", _borrowers());

        assertEq(marketId, keccak256(abi.encode("Market A", "Market A", address(collateral))));
        assertTrue(senior != address(0));
        assertTrue(junior != address(0));
        assertTrue(senior != junior);

        assertEq(Tranche(senior).asset(), address(collateral));
        assertEq(Tranche(junior).asset(), address(collateral));
    }

    function test_createMarket_duplicate_reverts() public {
        _createMarket("Market A", _borrowers());
        vm.expectRevert(ILender.MarketAlreadyExists.selector);
        _createMarket("Market A", _borrowers());
    }

    function test_createMarket_invalidLtv_reverts() public {
        address[] memory b = _borrowers();
        vm.expectRevert(ILender.InvalidLtv.selector);
        lender.createMarket("Bad", "Bad", address(collateral), 0.75e27, b); // 0.75 + 0.1 > 0.8
    }

    function test_setLtv_onlyAuthority() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert();
        lender.setLtv(marketId, 0.4e27);

        lender.setLtv(marketId, 0.4e27);
    }

    function test_addRemoveBorrower_onlyAuthority() public {
        bytes32 marketId = _market();
        lender.addBorrower(marketId, stranger);
        lender.removeBorrower(marketId, stranger);
    }

    function test_addBorrower_unauthorized_reverts() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert();
        lender.addBorrower(marketId, stranger);
    }

    function test_removeBorrower_unauthorized_reverts() public {
        bytes32 marketId = _market();
        vm.prank(stranger);
        vm.expectRevert();
        lender.removeBorrower(marketId, borrower);
    }

    function test_createMarket_duplicateBorrower_reverts() public {
        address[] memory dup = new address[](2);
        dup[0] = borrower;
        dup[1] = borrower;
        vm.expectRevert(ILender.InvalidBorrower.selector);
        lender.createMarket("Dup", "Dup", address(collateral), DEFAULT_LTV, dup);
    }

    function test_setLtv_invalid_reverts() public {
        bytes32 marketId = _market();
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
        assertEq(lender.getPrice(marketId), 1e27);
    }

    function test_upgrade_unauthorized_reverts() public {
        Lender newImpl = new Lender();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
    }

    function _market() internal returns (bytes32 marketId) {
        (marketId,,) = _createMarket("Market A", _borrowers());
    }
}
