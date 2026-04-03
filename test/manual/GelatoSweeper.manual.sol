// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { CapSweeper } from "../../contracts/gelato/CapSweeper.sol";
import { ICapSweeper } from "../../contracts/interfaces/ICapSweeper.sol";

import { IFractionalReserve } from "../../contracts/interfaces/IFractionalReserve.sol";
import { IVault } from "../../contracts/interfaces/IVault.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";

/// @dev Manual suite for simulating Gelato sweeping flows.
/// Intentionally contains no `test*` functions so it never runs in CI.
contract GelatoSweeperManual is Test {
    CapSweeper public impl;
    ERC1967Proxy public proxy;
    address public accessControl = address(0x7731129a10d51e18cDE607C5C115F26503D2c683);
    address public cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
    address public admin = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
    address public gelato = address(0xe84E4337c382cC8Ed57c6FB12919270228B6B7A3);

    uint256 public minSweepAmount = 1e18;
    uint256 public sweepInterval = 6 hours;

    function setUp() public {
        impl = new CapSweeper();

        bytes memory data =
            abi.encodeWithSelector(ICapSweeper.initialize.selector, accessControl, cusd, sweepInterval, minSweepAmount);
        proxy = new ERC1967Proxy(address(impl), data);

        vm.prank(admin);
        AccessControl(accessControl).grantAccess(ICapSweeper.sweep.selector, address(proxy), gelato);

        vm.prank(admin);
        AccessControl(accessControl).grantAccess(IFractionalReserve.investAll.selector, address(cusd), address(proxy));
    }

    function manual_gelatoSweep() public {
        (bool canExec,) = CapSweeper(address(proxy)).checker();
        if (!canExec) return;

        address[] memory assets = IVault(cusd).assets();
        vm.prank(gelato);
        ICapSweeper(address(proxy)).sweep(assets[0]);
    }
}

