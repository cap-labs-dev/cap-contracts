// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../../contracts/interfaces/IBeaconFactory.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
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

    function test_registry_listsMarketsTranchesAndUnderwriters() public {
        assertEq(registry.marketsLength(), 0);
        assertEq(registry.tranchesLength(), 0);
        assertEq(registry.underwritersLength(), 0);
        assertEq(registry.markets(0, 0).length, 0);

        (address marketA, address trancheA0, address trancheA1) = _createMarket("A");
        (address marketB, address trancheB0, address trancheB1) = _createMarket("B");
        address underwriter = address(_deployUnderwriter());

        assertTrue(registry.isMarket(marketA));
        assertTrue(registry.isMarket(marketB));
        assertTrue(registry.isTranche(trancheA0));
        assertTrue(registry.isTranche(trancheA1));
        assertTrue(registry.isTranche(trancheB0));
        assertTrue(registry.isTranche(trancheB1));
        assertFalse(registry.isTranche(marketA));
        assertTrue(registry.isUnderwriter(underwriter));
        assertFalse(registry.isUnderwriter(marketA));

        assertEq(registry.marketsLength(), 2);
        address[] memory markets = registry.markets(0, registry.marketsLength());
        assertEq(markets.length, 2);
        assertEq(markets[0], marketA);
        assertEq(markets[1], marketB);
        assertEq(registry.markets(0, 1)[0], marketA);
        assertEq(registry.markets(1, 2)[0], marketB);

        assertEq(registry.tranchesLength(), 4);
        address[] memory listedTranches = registry.tranches(0, 2);
        assertEq(listedTranches[0], trancheA0);
        assertEq(listedTranches[1], trancheA1);

        assertEq(registry.underwritersLength(), 1);
        assertEq(registry.underwriters(0, 1)[0], underwriter);

        uint256[] memory next = new uint256[](3);
        next[0] = 0.5e27;
        next[1] = 0.3e27;
        next[2] = 0.2e27;
        address added = registry.createTranche(marketB, address(collateral), next, registry.DEFAULT_VESTING_PERIOD());
        assertTrue(registry.isTranche(added));
        assertEq(registry.tranchesLength(), 5);
        assertEq(registry.tranches(4, 5)[0], added);

        vm.expectRevert(IRegistry.InvalidRange.selector);
        registry.markets(1, 0);
        assertEq(registry.markets(0, 3), markets);
        _assertRegistryPageBounds(registry.markets, 2);
        _assertRegistryPageBounds(registry.tranches, 5);
        _assertRegistryPageBounds(registry.underwriters, 1);
    }

    function test_registry_emptyCollectionsClampPages() public {
        _assertRegistryPageBounds(registry.markets, 0);
        _assertRegistryPageBounds(registry.tranches, 0);
        _assertRegistryPageBounds(registry.underwriters, 0);
    }

    function _assertRegistryPageBounds(
        function(uint256, uint256) external view returns (address[] memory) list,
        uint256 length
    ) internal {
        address[] memory all = list(0, length);
        assertEq(all.length, length);
        assertEq(list(0, type(uint256).max), all, "an oversized end returns the full collection");
        assertEq(list(length, length).length, 0);
        assertEq(list(length, type(uint256).max).length, 0, "start at the end returns an empty page");
        assertEq(list(length + 1, type(uint256).max).length, 0, "start past the end returns an empty page");
        assertEq(list(type(uint256).max, type(uint256).max).length, 0);
        if (length > 0) {
            address[] memory tail = list(length - 1, type(uint256).max);
            assertEq(tail.length, 1, "the last oversized page contains only the remaining entry");
            assertEq(tail[0], all[length - 1]);
        }
        vm.expectRevert(IRegistry.InvalidRange.selector);
        list(length + 2, length + 1);
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
        address added = registry.createTranche(marketAddr, address(collateral), next, registry.DEFAULT_VESTING_PERIOD());
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
