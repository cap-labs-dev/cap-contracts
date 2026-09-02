// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title FixedExtendTest
/// @notice A live loan must accept a finite extension up to the remaining room under the maximum
/// term. Passing `type(uint256).max` still fills that room in one shot.
contract FixedExtendTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1_000e18;

    function setUp() public {
        _deployCap();
    }

    function _ready() internal returns (FixedMarket market) {
        (address marketAddr, address t0,) = _createFixedMarket("Fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(10_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
    }

    function test_extend_liveLoanByFiniteTerm() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        uint256 expiryBefore = market.expiry(id);
        uint256 debtBefore = market.debt(id);

        uint256 actual = market.extend(id, 7 days);

        assertEq(actual, 7 days, "returns the requested extension");
        assertEq(market.expiry(id), expiryBefore + 7 days, "expiry moves by 7 days");
        assertGt(market.debt(id), debtBefore, "premium charged on the extension");
    }

    function test_extend_liveLoanMaxFillsRemainingRoom() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        uint256 actual = market.extend(id, type(uint256).max);

        assertEq(actual, 29 days, "max term is 30 days, 1 day already used");
        assertEq(market.expiry(id), block.timestamp + 30 days, "capped at maximum term");
    }

    function test_extend_liveLoanBeyondRemainingRoom_reverts() public {
        FixedMarket market = _ready();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 1 days);

        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extend(id, 30 days);
    }
}
