// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BeaconFactory } from "../../../contracts/cap/BeaconFactory.sol";
import { Registry } from "../../../contracts/cap/Registry.sol";
import { IRegistry } from "../../../contracts/interfaces/IRegistry.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract RegistryTest is BaseTest {
    function _validInit() internal view returns (IRegistry.InitParams memory init) {
        init = IRegistry.InitParams({
            stablecoin: address(1),
            vault: address(2),
            oracle: address(3),
            irm: address(4),
            factory: address(5),
            floatingMarketBeacon: address(6),
            fixedMarketBeacon: address(7),
            trancheBeacon: address(8),
            underwriterBeacon: address(9),
            lt: 0.8e27,
            buffer: 0.1e27,
            targetHealth: 1.25e27
        });
    }

    function _initRevertsOnZero(IRegistry.InitParams memory init) internal {
        Registry impl = new Registry();
        vm.expectRevert(IRegistry.ZeroAddress.selector);
        _deployProxy(address(impl), abi.encodeCall(Registry.initialize, (address(accessManager), init)));
    }

    function setUp() public {
        _setUpAccessManager();
    }

    function test_initialize_rejectsEachZeroAddress() public {
        IRegistry.InitParams memory init;

        init = _validInit();
        init.vault = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.stablecoin = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.oracle = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.irm = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.factory = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.floatingMarketBeacon = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.fixedMarketBeacon = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.trancheBeacon = address(0);
        _initRevertsOnZero(init);

        init = _validInit();
        init.underwriterBeacon = address(0);
        _initRevertsOnZero(init);
    }

    function _deployRegistry(IRegistry.InitParams memory init) internal returns (Registry registry) {
        Registry impl = new Registry();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        accessManager.grantRole(0, predicted, 0);
        registry = Registry(
            _deployProxy(address(impl), abi.encodeCall(Registry.initialize, (address(accessManager), init)))
        );
    }

    function test_registryUpgrade_authorized() public {
        Registry registry = _deployRegistry(_validInit());
        UUPSUpgradeable(address(registry)).upgradeToAndCall(address(new Registry()), "");
        assertEq(registry.vault(), address(2));
    }

    function test_registryUpgrade_unauthorized_reverts() public {
        Registry registry = _deployRegistry(_validInit());
        Registry newImpl = new Registry();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        UUPSUpgradeable(address(registry)).upgradeToAndCall(address(newImpl), "");
    }

    function test_beaconFactoryUpgrade_authorized() public {
        BeaconFactory factory = BeaconFactory(
            _deployProxy(
                address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (address(accessManager)))
            )
        );
        UUPSUpgradeable(address(factory)).upgradeToAndCall(address(new BeaconFactory()), "");
        assertEq(factory.authority(), address(accessManager));
    }

    function test_beaconFactoryUpgrade_unauthorized_reverts() public {
        BeaconFactory factory = BeaconFactory(
            _deployProxy(
                address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (address(accessManager)))
            )
        );
        BeaconFactory newImpl = new BeaconFactory();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        UUPSUpgradeable(address(factory)).upgradeToAndCall(address(newImpl), "");
    }
}
