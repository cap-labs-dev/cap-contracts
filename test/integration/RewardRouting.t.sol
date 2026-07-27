// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IMarket } from "../../contracts/interfaces/IMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract RewardRoutingTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal jSup = makeAddr("jSup");
    address internal sSup = makeAddr("sSup");
    uint64 internal managerId = MANAGER_ROLE;
    uint64 internal borrowerId = BORROWER_ROLE;

    function setUp() public {
        _deployCap();
    }

    function _setupMarket(string memory name, uint256 juniorAmt, uint256 seniorAmt)
        internal
        returns (Market m, address senior, address junior)
    {
        address marketAddr;
        (marketAddr, senior, junior) = _createMarket(name, managerId, borrowerId);
        accessManager.grantRole(BORROWER_ROLE, borrower, 0);
        m = Market(marketAddr);

        _setMarketSlopes(marketAddr);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        m.setMultiplier(1e27);
        m.setJuniorSplit(0.5e27);

        if (juniorAmt > 0) _fundTranche(junior, jSup, juniorAmt);
        if (seniorAmt > 0) _fundTranche(senior, sSup, seniorAmt);

        m.setBorrowCap(1_000e18);
    }

    function test_emptySenior_routesPremiumToJunior() public {
        (Market m, address senior, address junior) = _setupMarket("Senior Empty", 1_000e18, 0);

        vm.prank(borrower);
        m.borrow(borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        m.repay(1);

        assertGt(m.claimable(junior), 0);
        assertEq(m.claimable(senior), 0);
    }

    function test_emptyJunior_routesPremiumToSenior() public {
        (Market m, address senior, address junior) = _setupMarket("Junior Empty", 0, 1_000e18);

        vm.prank(borrower);
        m.borrow(borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        m.repay(1);

        assertGt(m.claimable(senior), 0);
        assertEq(m.claimable(junior), 0);
    }

    function test_liquidation_slashesJuniorThenSenior() public {
        (Market m, address senior, address junior) = _setupMarket("Slash", 600e18, 400e18);

        vm.prank(borrower);
        m.borrow(borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);

        uint256 max = m.maxLiquidatable();
        assertGt(max, 0);
        _mintStable(borrower, max);

        uint256 juniorBefore = Tranche(junior).totalAssets();
        uint256 seniorBefore = Tranche(senior).totalAssets();

        vm.prank(borrower);
        m.liquidate(borrower, max);

        assertLe(Tranche(junior).totalAssets(), juniorBefore);
        assertLe(Tranche(senior).totalAssets(), seniorBefore);
    }
}
