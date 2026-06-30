// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Rewarder } from "../../contracts/cap/Rewarder.sol";
import { IRewarder } from "../../contracts/interfaces/IRewarder.sol";
import { CapDeployer } from "./CapDeployer.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract RewarderTest is CapDeployer {
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    bytes32 internal marketId;
    address internal senior;
    address internal junior;

    event SetJuniorSplit(bytes32 marketId, uint256 juniorSplit);
    event SetStcUSD(address stcUSD);
    event RegisterMarket(bytes32 marketId, address seniorUnderwriter, address juniorUnderwriter);

    function setUp() public {
        _deployCap();
        address[] memory borrowers = new address[](0);
        (marketId, senior, junior) = _createMarket("Market A", manager, borrowers);
    }

    function test_registerMarket_onlyLender() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.registerMarket(marketId, senior, junior);
    }

    function test_setStcUSD_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        rewarder.setStcUSD(address(0xCAFE));
    }

    function test_setStcUSD_emits() public {
        vm.expectEmit(false, false, false, true);
        emit SetStcUSD(address(0xCAFE));
        rewarder.setStcUSD(address(0xCAFE));
    }

    function test_setJuniorSplit_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.setJuniorSplit(marketId, 0.5e27);
    }

    function test_setJuniorSplit_byTranche() public {
        vm.expectEmit(false, false, false, true);
        emit SetJuniorSplit(marketId, 0.5e27);
        vm.prank(senior);
        rewarder.setJuniorSplit(marketId, 0.5e27);
    }

    function test_setJuniorSplit_tooHigh_reverts() public {
        vm.prank(senior);
        vm.expectRevert(IRewarder.InvalidJuniorSplit.selector);
        rewarder.setJuniorSplit(marketId, 1e27 + 1);
    }

    function test_claimableSupplyReward_zeroInitially() public view {
        assertEq(rewarder.claimableSupplyReward(), 0);
    }

    function test_updateRewards_noDebt_isNoop() public {
        // with no scaled debt the call simply checkpoints indices without reverting
        rewarder.updateRewards(marketId);
        assertEq(rewarder.claimableSupplyReward(), 0);
    }

    function test_increaseRewardDebt_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.increaseRewardDebt(marketId, stranger, 1e18);
    }

    function test_decreaseRewardDebt_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.decreaseRewardDebt(marketId, stranger, 1e18);
    }

    function test_updateSupplyIndex_onlyLender() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.updateSupplyIndex(marketId);
    }

    function test_claimUnderwriterReward_wrongUnderwriter_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(IRewarder.Unauthorized.selector);
        rewarder.claimUnderwriterReward(marketId, stranger, stranger);
    }

    function test_upgrade_authorized() public {
        Rewarder newImpl = new Rewarder();
        UUPSUpgradeable(address(rewarder)).upgradeToAndCall(address(newImpl), "");
        assertEq(rewarder.claimableSupplyReward(), 0); // still functional
    }

    function test_upgrade_unauthorized_reverts() public {
        Rewarder newImpl = new Rewarder();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(rewarder)).upgradeToAndCall(address(newImpl), "");
    }
}
