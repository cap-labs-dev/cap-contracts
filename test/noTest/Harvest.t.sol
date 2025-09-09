// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { Harvester } from "../../contracts/fractionalReserve/Harvester.sol";

import { IFractionalReserve } from "../../contracts/interfaces/IFractionalReserve.sol";
import { IFractionalReserveStrategy } from "../../contracts/interfaces/IFractionalReserveStrategy.sol";
import { IFractionalReserveVault } from "../../contracts/interfaces/IFractionalReserveVault.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface IRoleManager {
    function updateKeeper(address _vault, address _keeper) external;
}

interface IManagement {
    function setAddresses(address _management, address _performanceFeeRecipient, address _keeper) external;
    function performanceFeeRecipient() external view returns (address);
}

contract HarvesterTest is Test {
    Harvester public harvester;
    IFractionalReserveStrategy public strategy;
    IRoleManager public roleManager;
    IManagement public management;
    address public performanceFeeRecipient;
    address public cusd;
    address public asset;
    address public msig;
    address public manager;

    function setUp() public {
        roleManager = IRoleManager(address(0x2995401cB465F3fbAE64a2D2f78Dfa571F570D24));
        msig = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);
        cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
        asset = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        manager = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
        address fractionalReserve = IFractionalReserve(cusd).fractionalReserveVault(asset);
        address[] memory queue = IFractionalReserveVault(fractionalReserve).get_default_queue();
        strategy = IFractionalReserveStrategy(queue[0]);

        harvester = new Harvester();

        vm.prank(manager);
        roleManager.updateKeeper(fractionalReserve, address(harvester));
        strategy.setKeeper(address(harvester));
        vm.stopPrank();
    }

    function test_harvest() public {
        (uint256 profit, uint256 loss, uint256 interest) = harvester.harvest(cusd, asset);
        console.log("profit", profit);
        console.log("loss", loss);
        console.log("interest", interest);
    }
}
