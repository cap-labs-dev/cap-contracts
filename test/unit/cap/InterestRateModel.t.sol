// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { InterestRateModel } from "../../../contracts/cap/InterestRateModel.sol";
import { IInterestRateModel } from "../../../contracts/interfaces/IInterestRateModel.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockUtilizationSource } from "../../shared/mocks/MockUtilizationSource.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract InterestRateModelTest is BaseTest {
    InterestRateModel internal irm;
    MockUtilizationSource internal src;

    bytes32 internal constant MARKET = keccak256("market");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpAccessManager();
        src = new MockUtilizationSource();

        InterestRateModel impl = new InterestRateModel();
        // stablecoin and lender are both served by the mock utilization source
        irm = InterestRateModel(
            _deployProxy(
                address(impl),
                abi.encodeCall(InterestRateModel.initialize, (address(src), address(src), address(accessManager)))
            )
        );
    }

    function _supplySlopes() internal pure returns (IInterestRateModel.Slopes memory s) {
        s = IInterestRateModel.Slopes({ base: 0, slope0: 0.1e27, slope1: 0.9e27, kink: 0.8e27 });
    }

    // --- supply side ---

    function test_initialIndexesAreRay() public view {
        assertEq(irm.variableIndex(), RAY);
        assertEq(irm.fixedIndex(), RAY);
    }

    function test_setVariableSlopes_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        irm.setVariableSlopes(_supplySlopes());
    }

    function test_variableRate_atKink() public {
        src.setSupplyUtilization(0.8e27); // == kink
        irm.setVariableSlopes(_supplySlopes());
        // base + slope0 * (util/kink) = 0 + 0.1 * 1 = 0.1
        assertEq(irm.variableRate(), 0.1e27);
    }

    function test_variableRate_aboveKink() public {
        src.setSupplyUtilization(0.9e27);
        irm.setVariableSlopes(_supplySlopes());
        // base + slope0 + slope1 * ((0.9-0.8)/(1-0.8)) = 0.1 + 0.9*0.5 = 0.55
        assertEq(irm.variableRate(), 0.55e27);
    }

    function test_variableIndex_growsOverTime() public {
        src.setSupplyUtilization(0.8e27);
        irm.setVariableSlopes(_supplySlopes());
        uint256 before = irm.variableIndex();
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.variableIndex(), before);
    }

    function test_fixedSlopes_independentFromVariable() public {
        src.setSupplyUtilization(0.5e27);
        IInterestRateModel.Slopes memory f =
            IInterestRateModel.Slopes({ base: 0.02e27, slope0: 0.04e27, slope1: 0.5e27, kink: 0.9e27 });
        irm.setFixedSlopes(f);
        // util(0.5) <= kink(0.9): base + slope0*(0.5/0.9)
        uint256 expected = 0.02e27 + uint256(0.04e27) * 0.5e27 / 0.9e27;
        assertApproxEqAbs(irm.fixedRate(), expected, 1e9);
        assertEq(irm.variableRate(), 0); // variable never configured
    }

    // --- inverse side ---

    function test_inverse_indexZeroUntilSlopesSet() public view {
        assertEq(irm.index(MARKET), 0);
    }

    function test_inverse_setSlopes_invalid_baseLtSlope0() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.1e27, slope0: 0.2e27, slope1: 0, kink: 0.5e27 });
        vm.expectRevert(IInterestRateModel.InvalidSlopes.selector);
        irm.setMarketSlopes(MARKET, s);
    }

    function test_inverse_setSlopes_invalid_kink() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0, kink: 0 });
        vm.expectRevert(IInterestRateModel.InvalidSlopes.selector);
        irm.setMarketSlopes(MARKET, s);

        s.kink = 1e27;
        vm.expectRevert(IInterestRateModel.InvalidSlopes.selector);
        irm.setMarketSlopes(MARKET, s);
    }

    function test_inverse_setSlopes_initializesIndexToRay() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        irm.setMarketSlopes(MARKET, s);
        assertEq(irm.index(MARKET), RAY);
    }

    function test_inverse_rate_decreasesWithUtilizationBelowKink() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        src.setMarketUtilization(MARKET, 0); // util 0 -> rate = base
        irm.setMarketSlopes(MARKET, s);
        assertEq(irm.rate(MARKET), 0.2e27);

        src.setMarketUtilization(MARKET, 0.5e27); // util == kink -> base - slope0 = 0.1
        irm.update(MARKET);
        assertEq(irm.rate(MARKET), 0.1e27);
    }

    function test_inverse_index_growsOverTime() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        irm.setMarketSlopes(MARKET, s);
        uint256 before = irm.index(MARKET);
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.index(MARKET), before);
    }

    function test_inverse_marketsAreIndependent() public {
        bytes32 other = keccak256("other");
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        irm.setMarketSlopes(MARKET, s);
        assertEq(irm.index(MARKET), RAY);
        assertEq(irm.index(other), 0); // untouched
    }

    function test_inverse_rate_aboveKink() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        src.setMarketUtilization(MARKET, 0.8e27); // util > kink
        irm.setMarketSlopes(MARKET, s);
        // base - slope0 + slope1 * ((0.8-0.5)/(1-0.5)) = 0.1 + 0.3*0.6 = 0.28
        assertEq(irm.rate(MARKET), 0.28e27);
        // nextInterestRate recomputes from current utilization and matches
        assertEq(irm.nextInterestRate(MARKET), 0.28e27);
    }

    function test_supply_rate_aboveKink() public {
        src.setSupplyUtilization(0.9e27); // util > kink (0.8)
        irm.setVariableSlopes(_supplySlopes());
        // base + slope0 + slope1*((0.9-0.8)/(1-0.8)) = 0.1 + 0.9*0.5 = 0.55
        assertEq(irm.variableRate(), 0.55e27);
    }

    function test_upgrade_authorized() public {
        InterestRateModel newImpl = new InterestRateModel();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
        assertEq(irm.variableIndex(), RAY); // still functional
    }

    function test_upgrade_unauthorized_reverts() public {
        InterestRateModel newImpl = new InterestRateModel();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
    }
}
