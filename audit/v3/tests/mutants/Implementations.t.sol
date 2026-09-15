// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BeaconFactory } from "../../../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../../contracts/cap/Vault.sol";
import { Wrapper } from "../../../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IRegistry } from "../../../../contracts/interfaces/IRegistry.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Kills the `_disableInitializers()` deletions (Gambit `<Contract>#1` for every
/// contract): the implementation behind each proxy or beacon must refuse `initialize`.
contract ImplementationsKillTest is CapDeployer {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _deployCap();
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function test_beaconImplementationsCannotBeInitialised() public {
        address a = address(accessManager);

        FloatingMarket fm = FloatingMarket(UpgradeableBeacon(floatingMarketBeacon).implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fm.initialize(a, address(registry), "x");

        FixedMarket fx = FixedMarket(UpgradeableBeacon(fixedMarketBeacon).implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fx.initialize(a, address(registry), "x", 30 days, 1 days, 1 days);

        Tranche t = Tranche(UpgradeableBeacon(trancheBeacon).implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        t.initialize(
            a, address(registry), address(collateral), "x", "x", address(this), address(vault), address(oracle)
        );

        Underwriter u = Underwriter(UpgradeableBeacon(underwriterBeacon).implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        u.initialize(a, address(registry), "x", "x", address(collateral), address(vault), address(stablecoin));
    }

    function test_uupsImplementationsCannotBeInitialised() public {
        address a = address(accessManager);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Stablecoin(_impl(address(stablecoin)))
            .initialize(a, address(cusdUnderlying), "x", "x", address(irm), address(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        InterestRateModel(_impl(address(irm))).initialize(a, address(stablecoin), 1e27, 2e27, 1e27, 0.02e27, 1 hours);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Oracle(_impl(address(oracle))).initialize(a);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Vault(_impl(address(vault))).initialize(a);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        BeaconFactory(_impl(address(beaconFactory))).initialize(a);

        IRegistry.InitParams memory init = IRegistry.InitParams({
            stablecoin: address(stablecoin),
            vault: address(vault),
            oracle: address(oracle),
            irm: address(irm),
            factory: address(beaconFactory),
            floatingMarketBeacon: floatingMarketBeacon,
            fixedMarketBeacon: fixedMarketBeacon,
            trancheBeacon: trancheBeacon,
            underwriterBeacon: underwriterBeacon,
            lt: 0.8e27,
            buffer: 0.1e27,
            targetHealth: 1.25e27
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Registry(_impl(address(registry))).initialize(a, init);

        Wrapper w = new Wrapper();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        w.initialize(a, address(stablecoin));
    }
}
