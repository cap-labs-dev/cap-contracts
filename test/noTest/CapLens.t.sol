// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import {
    SymbioticNetworkMiddleware
} from "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { IDelegation } from "../../contracts/interfaces/IDelegation.sol";
import { CapLens } from "../../contracts/lens/CapLens.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract CapLensTest is Test {
    CapLens public lens;

    address public delegation = address(0xF3E3Eae671000612CE3Fd15e1019154C1a4d693F);
    address public symbioticAgent = address(0xbAfa91d22C093E42E28D7Be417e38244E4153f78);
    address public eigenAgent = address(0x5f33ff3027c4763D36e6f4F7C20eE72F700A5D34);
    uint256 public constant BLOCK_TIMESTAMP = 1771380323;
    uint256 public constant BLOCK_NUMBER = 24480618;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        address symbioticMiddlewareProxy = IDelegation(delegation).networks(symbioticAgent);
        SymbioticNetworkMiddleware newSymbioticImpl = new SymbioticNetworkMiddleware();
        vm.store(
            symbioticMiddlewareProxy, ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(newSymbioticImpl))))
        );

        address eigenMiddlewareProxy = IDelegation(delegation).networks(eigenAgent);
        EigenServiceManager newEigenImpl = new EigenServiceManager();
        vm.store(eigenMiddlewareProxy, ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(newEigenImpl)))));

        lens = new CapLens(delegation);
        vm.warp(BLOCK_TIMESTAMP);
        vm.roll(BLOCK_NUMBER);
    }

    function test_slashableCollateral_epochDiff0() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(symbioticAgent, 0);
        console.log("slashableCollateral(symbioticAgent, 0) value", value);
        console.log("slashableCollateral(symbioticAgent, 0) amount", amount);
        assertEq(value, 3477449402625758);
        assertEq(amount, 51996053445);
    }

    function test_slashableCollateral_epochDiff1() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(symbioticAgent, 1);
        console.log("slashableCollateral(symbioticAgent, 1) value", value);
        console.log("slashableCollateral(symbioticAgent, 1) amount", amount);
        assertEq(value, 0);
        assertEq(amount, 0);
    }

    function test_slashableCollateral_epochDiff2() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(symbioticAgent, 2);
        console.log("slashableCollateral(symbioticAgent, 2) value", value);
        console.log("slashableCollateral(symbioticAgent, 2) amount", amount);
        assertEq(value, 0);
        assertEq(amount, 0);
    }

    function test_coverage_epochDiff0() public view {
        (uint256 value, uint256 amount) = lens.coverage(symbioticAgent, 0);
        console.log("coverage(symbioticAgent, 0) value", value);
        console.log("coverage(symbioticAgent, 0) amount", amount);
        assertEq(value, 3477449402625758);
        assertEq(amount, 51996053445);
    }

    function test_coverage_epochDiff1() public view {
        (uint256 value, uint256 amount) = lens.coverage(symbioticAgent, 1);
        console.log("coverage(symbioticAgent, 1) value", value);
        console.log("coverage(symbioticAgent, 1) amount", amount);
        assertEq(value, 3477449402625758);
        assertEq(amount, 51996053445);
    }

    function test_coverage_epochDiff2() public view {
        (uint256 value, uint256 amount) = lens.coverage(symbioticAgent, 2);
        console.log("coverage(symbioticAgent, 2) value", value);
        console.log("coverage(symbioticAgent, 2) amount", amount);
        assertEq(value, 3477449402625758);
        assertEq(amount, 51996053445);
    }

    // EigenLayer agent 0x5f33ff3027c4763D36e6f4F7C20eE72F700A5D34
    function test_slashableCollateral_eigen_epochDiff0() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(eigenAgent, 0);
        console.log("slashableCollateral(eigenAgent, 0) value", value);
        console.log("slashableCollateral(eigenAgent, 0) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 0);
    }

    function test_slashableCollateral_eigen_epochDiff1() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(eigenAgent, 1);
        console.log("slashableCollateral(eigenAgent, 1) value", value);
        console.log("slashableCollateral(eigenAgent, 1) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 0);
    }

    function test_slashableCollateral_eigen_epochDiff2() public view {
        (uint256 value, uint256 amount) = lens.slashableCollateral(eigenAgent, 2);
        console.log("slashableCollateral(eigenAgent, 2) value", value);
        console.log("slashableCollateral(eigenAgent, 2) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 0);
    }

    function test_coverage_eigen_epochDiff0() public view {
        (uint256 value, uint256 amount) = lens.coverage(eigenAgent, 0);
        console.log("coverage(eigenAgent, 0) value", value);
        console.log("coverage(eigenAgent, 0) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 267989218211098297328);
    }

    function test_coverage_eigen_epochDiff1() public view {
        (uint256 value, uint256 amount) = lens.coverage(eigenAgent, 1);
        console.log("coverage(eigenAgent, 1) value", value);
        console.log("coverage(eigenAgent, 1) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 267989218211098297328);
    }

    function test_coverage_eigen_epochDiff2() public view {
        (uint256 value, uint256 amount) = lens.coverage(eigenAgent, 2);
        console.log("coverage(eigenAgent, 2) value", value);
        console.log("coverage(eigenAgent, 2) amount", amount);
        assertEq(value, 52846702495817);
        assertEq(amount, 267989218211098297328);
    }
}
