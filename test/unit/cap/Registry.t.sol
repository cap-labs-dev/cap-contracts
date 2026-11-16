// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BeaconFactory } from "../../../contracts/cap/BeaconFactory.sol";
import { Registry } from "../../../contracts/cap/Registry.sol";
import { IBeaconFactory } from "../../../contracts/interfaces/IBeaconFactory.sol";
import { IRegistry } from "../../../contracts/interfaces/IRegistry.sol";
import { CapRoles } from "../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract DummyBeaconImpl { }

contract RegistryTest is BaseTest {
    function _validInit() internal view returns (IRegistry.InitParams memory init) {
        init = IRegistry.InitParams({
            stablecoin: address(1),
            oracle: address(3),
            irm: address(4),
            factory: address(5),
            floatingMarketBeacon: address(6),
            fixedMarketBeacon: address(7),
            trancheBeacon: address(8),
            underwriterBeacon: address(9),
            wrapper: address(10)
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

        init = _validInit();
        init.wrapper = address(0);
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

    function test_protocolFee_defaultsOff() public {
        Registry registry = _deployRegistry(_validInit());
        (address receiver, uint256 liquidityRate, uint256 underwriterRate) = registry.protocolFee();
        assertEq(receiver, address(0));
        assertEq(liquidityRate, 0);
        assertEq(underwriterRate, 0);
        assertEq(registry.feeReceiver(), address(0));
        assertEq(registry.liquidityFeeRate(), 0);
        assertEq(registry.underwriterFeeRate(), 0);
    }

    function test_setProtocolFee_governorSetsAndEmits() public {
        Registry registry = _deployRegistry(_validInit());
        address governor = makeAddr("governor");
        accessManager.grantRole(CapRoles.GOVERNOR, governor, 0);
        address receiver = makeAddr("fee receiver");

        vm.expectEmit(address(registry));
        emit IRegistry.SetProtocolFee(receiver, 0.1e27, 0.25e27);
        vm.prank(governor);
        registry.setProtocolFee(receiver, 0.1e27, 0.25e27);

        (address got, uint256 liquidityRate, uint256 underwriterRate) = registry.protocolFee();
        assertEq(got, receiver);
        assertEq(liquidityRate, 0.1e27);
        assertEq(underwriterRate, 0.25e27);
        assertEq(registry.MAX_FEE_RATE(), 0.5e27);
    }

    function test_setProtocolFee_zeroReceiverSwitchesOff() public {
        Registry registry = _deployRegistry(_validInit());
        accessManager.grantRole(CapRoles.GOVERNOR, address(this), 0);
        registry.setProtocolFee(makeAddr("fee receiver"), 0.1e27, 0.1e27);
        registry.setProtocolFee(address(0), 0, 0);
        (address receiver, uint256 liquidityRate, uint256 underwriterRate) = registry.protocolFee();
        assertEq(receiver, address(0));
        assertEq(liquidityRate, 0);
        assertEq(underwriterRate, 0);
    }

    function test_setProtocolFee_rejectsRateAboveCapOnEitherLeg() public {
        Registry registry = _deployRegistry(_validInit());
        accessManager.grantRole(CapRoles.GOVERNOR, address(this), 0);
        address receiver = makeAddr("fee receiver");
        vm.expectRevert(IRegistry.InvalidFeeRate.selector);
        registry.setProtocolFee(receiver, 0.5e27 + 1, 0);
        vm.expectRevert(IRegistry.InvalidFeeRate.selector);
        registry.setProtocolFee(receiver, 0, 0.5e27 + 1);
        registry.setProtocolFee(receiver, 0.5e27, 0.5e27);
    }

    function test_setProtocolFee_rejectsRatesWithoutReceiver() public {
        Registry registry = _deployRegistry(_validInit());
        accessManager.grantRole(CapRoles.GOVERNOR, address(this), 0);
        vm.expectRevert(IRegistry.FeeReceiverRequired.selector);
        registry.setProtocolFee(address(0), 1, 0);
        vm.expectRevert(IRegistry.FeeReceiverRequired.selector);
        registry.setProtocolFee(address(0), 0, 1);
    }

    function test_setProtocolFee_nonGovernorReverts() public {
        Registry registry = _deployRegistry(_validInit());
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        registry.setProtocolFee(makeAddr("fee receiver"), 0.1e27, 0.1e27);
        // the admin is not the governor either
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        registry.setProtocolFee(makeAddr("fee receiver"), 0.1e27, 0.1e27);
    }

    function test_registryUpgrade_authorized() public {
        Registry registry = _deployRegistry(_validInit());
        UUPSUpgradeable(address(registry)).upgradeToAndCall(address(new Registry()), "");
        assertEq(registry.oracle(), address(3));
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

    /// @dev The beacon is the type key.
    function test_beaconFactoryCreate_emitsBeaconAndProxy() public {
        BeaconFactory factory = BeaconFactory(
            _deployProxy(
                address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (address(accessManager)))
            )
        );
        address beacon = address(new UpgradeableBeacon(address(new DummyBeaconImpl()), address(this)));
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(address(factory));
        emit IBeaconFactory.Deployed(beacon, predicted);
        assertEq(factory.create(beacon, ""), predicted);
    }
}
