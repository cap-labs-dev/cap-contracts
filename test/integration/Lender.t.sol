// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../../contracts/interfaces/IBeaconFactory.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { Vm } from "forge-std/Vm.sol";

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

    function test_newMarketCopiesIrmRiskDefaults() public {
        (address marketAddr,) = registry.createFloatingMarket(
            _uniformAssets(2), capConfig.defaultTrancheWeights, "defaults", _operatorRoleOf(defaultMarketOwner)
        );
        FloatingMarket created = FloatingMarket(marketAddr);
        assertEq(created.liquidationThreshold(), irm.liquidationThreshold());
        assertEq(created.buffer(), irm.buffer());
        assertEq(created.targetHealth(), irm.targetHealth());
        assertEq(created.loanToValue(), 0);
    }

    function test_setMaxCapital_onlyAuthority() public {
        market = _market();
        address tranche = market.tranches()[0].tranche;
        vm.prank(stranger);
        vm.expectRevert();
        ITranche(tranche).setMaxCapital(1e18);
    }

    function test_setMaxCapital_effect() public {
        market = _market();
        IBaseMarket.Tranche[] memory ts = market.tranches();
        ITranche(ts[0].tranche).setMaxCapital(100e18);
        ITranche(ts[1].tranche).setMaxCapital(23e18);
        assertEq(ITranche(ts[0].tranche).maxCapital(), 100e18);
        assertEq(ITranche(ts[1].tranche).maxCapital(), 23e18);
    }

    function test_setTargetHealth_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setTargetHealth(1.2e27);
    }

    function test_createFloatingMarket_returnsNonZeroAddresses() public {
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

    /// @dev Factory logs name the beacon, so a market, tranche, and underwriter are distinguishable.
    function test_factoryDeployed_tagsBeacon() public {
        vm.recordLogs();
        (address marketAddr, address tranche0, address tranche1) = _createMarket("Tagged");
        Vm.Log[] memory created = vm.getRecordedLogs();
        _assertDeployed(created, registry.floatingMarketBeacon(), marketAddr);
        _assertDeployed(created, registry.trancheBeacon(), tranche0);
        _assertDeployed(created, registry.trancheBeacon(), tranche1);

        uint256[] memory next = new uint256[](3);
        next[0] = 0.5e27;
        next[1] = 0.3e27;
        next[2] = 0.2e27;
        vm.recordLogs();
        address added = registry.createTranche(marketAddr, address(collateral), next);
        _assertDeployed(vm.getRecordedLogs(), registry.trancheBeacon(), added);

        vm.recordLogs();
        address underwriter = address(_deployUnderwriter());
        _assertDeployed(vm.getRecordedLogs(), registry.underwriterBeacon(), underwriter);
    }

    function _assertDeployed(Vm.Log[] memory logs, address beacon, address proxy) internal view {
        bytes32 sig = keccak256("Deployed(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(beaconFactory) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != proxy) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), beacon);
            return;
        }
        revert("missing Deployed");
    }

    function test_setLoanToValue_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setLoanToValue(0.4e27);

        market.setLoanToValue(0.4e27);
    }

    function test_setLoanToValue_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IBaseMarket.InvalidLoanToValue.selector);
        market.setLoanToValue(0.75e27);
    }

    function test_setBuffer_and_setLiquidationThreshold_success() public {
        market = _market();
        market.setBuffer(0.2e27);
        market.setLiquidationThreshold(0.85e27);
    }

    function test_setMultiplier_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        market.setMarketMultiplier(11e27);
    }

    function test_setMultiplier_success() public {
        market = _market();
        market.setMarketMultiplier(2e27);
        assertEq(market.marketMultiplier(), 2e27);
        market.setMarketMultiplier(1.5e27);
        assertEq(market.marketMultiplier(), 1.5e27);
    }
}
