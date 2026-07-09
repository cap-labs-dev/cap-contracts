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
    MockUtilizationSource internal market;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpAccessManager();
        src = new MockUtilizationSource();
        market = new MockUtilizationSource();

        InterestRateModel impl = new InterestRateModel();
        irm = InterestRateModel(
            _deployProxy(
                address(impl), abi.encodeCall(InterestRateModel.initialize, (address(src), address(accessManager)))
            )
        );
    }

    function _supplySlopes() internal pure returns (IInterestRateModel.Slopes memory s) {
        s = IInterestRateModel.Slopes({ base: 0, slope0: 0.1e27, slope1: 0.9e27, kink: 0.8e27 });
    }

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
        src.setSupplyUtilization(0.8e27);
        irm.setVariableSlopes(_supplySlopes());
        assertEq(irm.variableRate(), 0.1e27);
    }

    function test_variableRate_aboveKink() public {
        src.setSupplyUtilization(0.9e27);
        irm.setVariableSlopes(_supplySlopes());
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
        uint256 expected = 0.02e27 + uint256(0.04e27) * 0.5e27 / 0.9e27;
        assertApproxEqAbs(irm.fixedRate(), expected, 1e9);
        assertEq(irm.variableRate(), 0);
    }

    function test_inverse_indexZeroUntilSlopesSet() public view {
        assertEq(irm.underwriterIndex(address(market)), 0);
    }

    function test_inverse_setSlopes_invalid_baseLtSlope0() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.1e27, slope0: 0.2e27, slope1: 0, kink: 0.5e27 });
        vm.expectRevert(IInterestRateModel.InvalidSlopes.selector);
        irm.setUnderwriterSlopes(address(market), s);
    }

    function test_inverse_setSlopes_initializesIndexToRay() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        irm.setUnderwriterSlopes(address(market), s);
        assertEq(irm.underwriterIndex(address(market)), RAY);
    }

    function test_inverse_rate_decreasesWithUtilizationBelowKink() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        market.setMarketUtilization(address(market), 0);
        irm.setUnderwriterSlopes(address(market), s);
        assertEq(irm.underwriterRate(address(market)), 0.2e27);

        market.setMarketUtilization(address(market), 0.5e27);
        irm.update(address(market));
        assertEq(irm.underwriterRate(address(market)), 0.1e27);
    }

    function test_inverse_index_growsOverTime() public {
        IInterestRateModel.Slopes memory s =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        irm.setUnderwriterSlopes(address(market), s);
        uint256 before = irm.underwriterIndex(address(market));
        vm.warp(block.timestamp + 365 days);
        assertGt(irm.underwriterIndex(address(market)), before);
    }

    function test_upgrade_authorized() public {
        InterestRateModel newImpl = new InterestRateModel();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
        assertEq(irm.variableIndex(), RAY);
    }

    function test_upgrade_unauthorized_reverts() public {
        InterestRateModel newImpl = new InterestRateModel();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(irm)).upgradeToAndCall(address(newImpl), "");
    }
}
