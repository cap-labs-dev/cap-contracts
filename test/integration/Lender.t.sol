// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract MarketTest is CapDeployer {
    address internal stranger = makeAddr("stranger");
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
    }

    function _market() internal returns (FloatingMarket m) {
        address marketAddr;
        (marketAddr,,) = _createMarket("Market A");
        m = FloatingMarket(marketAddr);
    }

    function test_setFixedCreditLimit_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setFixedCreditLimit(1e18);
    }

    function test_setFixedCreditLimit_effect() public {
        market = _market();
        market.setFixedCreditLimit(123e18);
        assertEq(market.fixedCreditLimit(), 123e18);
    }

    function test_setTargetHealth_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setTargetHealth(1.2e27);
    }

    function test_createMarket_returnsNonZeroAddresses() public {
        address marketAddr;
        address tranche0;
        address tranche1;
        (marketAddr, tranche0, tranche1) = _createMarket("Market A");

        assertTrue(marketAddr != address(0));
        assertTrue(tranche0 != address(0));
        assertTrue(tranche1 != address(0));
        assertTrue(tranche0 != tranche1);

        assertEq(Tranche(tranche0).asset(), address(collateral));
        assertEq(Tranche(tranche1).asset(), address(collateral));
        assertEq(FloatingMarket(marketAddr).tranches()[0].tranche, tranche0);
        assertEq(FloatingMarket(marketAddr).tranches()[1].tranche, tranche1);
    }

    function test_setLtv_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setLtv(0.4e27);

        market.setLtv(0.4e27);
    }

    function test_setLtv_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IBaseMarket.InvalidLtv.selector);
        market.setLtv(0.75e27);
    }

    function test_setBuffer_and_setLt_success() public {
        market = _market();
        market.setBuffer(0.2e27);
        market.setLt(0.85e27);
    }

    function test_setMultiplier_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        market.setMarketMultiplier(11e27);
    }

    function test_setMultiplier_success() public {
        market = _market();
        market.setMarketMultiplier(2e27);
    }
}
