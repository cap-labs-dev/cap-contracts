// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract RewardRoutingTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal supplier0 = makeAddr("supplier0");
    address internal supplier1 = makeAddr("supplier1");

    function setUp() public {
        _deployCap();
    }

    function _setupMarket(string memory name, uint256 tranche0Amt, uint256 tranche1Amt)
        internal
        returns (FloatingMarket m, address tranche0, address tranche1)
    {
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e27;
        weights[1] = 0.5e27;

        address marketAddr;
        address[] memory tranches;
        (marketAddr, tranches) = _createMarket(name, defaultMarketOwner, defaultBorrower, weights);
        tranche0 = tranches[0];
        tranche1 = tranches[1];
        m = FloatingMarket(marketAddr);

        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        m.setMarketMultiplier(1e27);

        if (tranche0Amt > 0) _fundTranche(tranche0, supplier0, tranche0Amt);
        if (tranche1Amt > 0) _fundTranche(tranche1, supplier1, tranche1Amt);

        m.setFixedCreditLimit(1_000e18);
    }

    function test_emptyTranche0_routesPremiumToTranche1() public {
        (FloatingMarket m, address tranche0, address tranche1) = _setupMarket("Tranche0 Empty", 0, 1_000e18);

        vm.prank(borrower);
        m.borrow(borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        m.repay(1);

        vm.warp(block.timestamp + 6 hours);

        assertGt(Tranche(tranche1).claimable(supplier1), 0);
        assertEq(Tranche(tranche0).claimable(supplier0), 0);
    }

    function test_emptyTranche1_routesPremiumToTranche0() public {
        (FloatingMarket m, address tranche0, address tranche1) = _setupMarket("Tranche1 Empty", 1_000e18, 0);

        vm.prank(borrower);
        m.borrow(borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        m.repay(1);

        vm.warp(block.timestamp + 6 hours);

        assertGt(Tranche(tranche0).claimable(supplier0), 0);
        assertEq(Tranche(tranche1).claimable(supplier1), 0);
    }

    function test_liquidation_slashesTranche1ThenTranche0() public {
        (FloatingMarket m, address tranche0, address tranche1) = _setupMarket("Slash", 400e18, 600e18);

        vm.prank(borrower);
        m.borrow(borrower, 500e18);
        vm.warp(block.timestamp + 3650 days);

        uint256 max = m.maxLiquidatable();
        assertGt(max, 0);
        _mintStable(defaultLiquidator, max);

        uint256 tranche1Before = Tranche(tranche1).totalAssets();
        uint256 tranche0Before = Tranche(tranche0).totalAssets();

        vm.prank(defaultLiquidator);
        m.liquidate(borrower, max);

        assertLe(Tranche(tranche1).totalAssets(), tranche1Before);
        assertLe(Tranche(tranche0).totalAssets(), tranche0Before);
    }
}
