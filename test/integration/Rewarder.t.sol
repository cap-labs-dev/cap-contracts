// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract RewarderTest is CapDeployer {
    address internal stranger = makeAddr("stranger");
    address internal supplier = makeAddr("supplier");
    FloatingMarket internal market;
    address internal tranche0;
    address internal tranche1;

    function setUp() public {
        _deployCap();
        address marketAddr;
        (marketAddr, tranche0, tranche1) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);
    }

    function test_setStakedStablecoin_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.setStakedStablecoin(address(0xCAFE));
    }

    function test_setStakedStablecoin_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IBaseMarket.SetStakedStablecoin(address(0xCAFE));
        market.setStakedStablecoin(address(0xCAFE));
    }

    function test_setTrancheWeights_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e27;
        weights[1] = 0.5e27;
        market.setTrancheWeights(weights);
    }

    function test_setTrancheWeights_byManager() public {
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e27;
        weights[1] = 0.5e27;
        market.setTrancheWeights(weights);
        assertEq(market.tranches()[0].weight, 0.5e27);
        assertEq(market.tranches()[1].weight, 0.5e27);
    }

    function test_setTrancheWeights_invalidTotal_reverts() public {
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1e27 + 1;
        weights[1] = 0;
        vm.expectRevert(IBaseMarket.InvalidTrancheWeightsTotal.selector);
        market.setTrancheWeights(weights);
    }

    function test_claimable_zeroInitially() public view {
        assertEq(Tranche(tranche1).claimable(supplier), 0);
        assertEq(Tranche(tranche0).claimable(supplier), 0);
    }
}
