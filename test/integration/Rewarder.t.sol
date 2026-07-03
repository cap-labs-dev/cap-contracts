// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Lender } from "../../contracts/cap/Lender.sol";
import { ILender } from "../../contracts/interfaces/ILender.sol";
import { CapDeployer } from "./CapDeployer.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract RewarderTest is CapDeployer {
    address internal stranger = makeAddr("stranger");

    bytes32 internal marketId;
    address internal senior;
    address internal junior;

    function setUp() public {
        _deployCap();
        address[] memory borrowers = new address[](0);
        (marketId, senior, junior) = _createMarket("Market A", borrowers);
    }

    function test_setStcUSD_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setStcUSD(address(0xCAFE));
    }

    function test_setStcUSD_emits() public {
        vm.expectEmit(false, false, false, true);
        emit ILender.SetStcUSD(address(0xCAFE));
        lender.setStcUSD(address(0xCAFE));
    }

    function test_setJuniorSplit_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.setJuniorSplit(marketId, 0.5e27);
    }

    function test_setJuniorSplit_byTranche() public {
        vm.expectEmit(false, false, false, true);
        emit ILender.SetJuniorSplit(marketId, 0.5e27);
        vm.prank(senior);
        lender.setJuniorSplit(marketId, 0.5e27);
    }

    function test_setJuniorSplit_tooHigh_reverts() public {
        vm.prank(senior);
        vm.expectRevert(ILender.InvalidJuniorSplit.selector);
        lender.setJuniorSplit(marketId, 1e27 + 1);
    }

    function test_claimableSupplyReward_zeroInitially() public view {
        assertEq(lender.claimableSupplyReward(), 0);
    }

    function test_updateRewards_noDebt_isNoop() public {
        lender.updateRewards(marketId);
        assertEq(lender.claimableSupplyReward(), 0);
    }

    function test_increaseRewardDebt_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.increaseRewardDebt(marketId, stranger, 1e18);
    }

    function test_decreaseRewardDebt_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.decreaseRewardDebt(marketId, stranger, 1e18);
    }

    function test_claimTrancheReward_zeroForStranger() public view {
        assertEq(lender.claimableTrancheReward(senior, stranger), 0);
    }

    function test_upgrade_authorized() public {
        Lender newImpl = new Lender();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
        assertEq(lender.claimableSupplyReward(), 0);
    }

    function test_upgrade_unauthorized_reverts() public {
        Lender newImpl = new Lender();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
    }
}
