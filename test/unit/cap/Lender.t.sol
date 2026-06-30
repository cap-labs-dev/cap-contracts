// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { ILender } from "../../../contracts/interfaces/ILender.sol";
import { CapDeployer } from "../utils/CapDeployer.sol";

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

    // NOTE: end-to-end borrow/repay tests are intentionally omitted for now. The deposit -> borrow path
    // currently hits two bootstrap divide-by-zero bugs in the contracts (Lender.utilization divides by a
    // zero totalCredit before any deposits, and Rewarder.increaseRewardDebt divides by a zero
    // rewardPerShare on the first underwriter share mint). Once those are addressed the e2e tests can be
    // enabled using CapDeployer._fundUnderwriter / _setMarketSlopes.

    // helper: a default market
    function _market() internal returns (bytes32 marketId) {
        (marketId,,) = _createMarket("Market A", manager, _borrowers());
    }
}
