// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Local audit characterization tests. Passing records current defective behavior;
/// update assertions to the required invariant when implementing the corresponding fix.
contract AuditValidationTest is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_audit_guardianLtReductionDoesNotConstrainFloatingBorrow() public {
        (address m, address t,) = _createMarket("risk limits");
        FloatingMarket market = FloatingMarket(m);
        _fundTranche(t, makeAddr("supplier"), 2_000e18);
        market.setLt(0.2e27);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);
        assertLt(market.healthiness(), 1e27);
    }

    function test_audit_overdueRepaymentDoesNotSettleArrears() public {
        (address m, address t,) = _createFixedMarket("maturity");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(0.2e27);
        _fundTranche(t, makeAddr("supplier"), 10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 500e18, 1 days);
        uint256 initialDebt = market.debt(id);
        _depositStable(defaultBorrower, 100e18);
        vm.warp(market.expiry(id) + 365 days);
        assertEq(market.debt(id), initialDebt);
        vm.prank(defaultBorrower);
        assertEq(market.repay(id, type(uint256).max), initialDebt);
    }

    function test_audit_lowerMaximumTermBreaksLiveExtension() public {
        (address m, address t,) = _createFixedMarket("term changes");
        FixedMarket market = FixedMarket(m);
        _fundTranche(t, makeAddr("supplier"), 10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 500e18, 30 days);
        market.setTermLimits(7 days, 1 days);
        vm.prank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        market.extend(id, 1 days);
    }
}
