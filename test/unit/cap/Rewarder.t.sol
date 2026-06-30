// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Rewarder } from "../../../contracts/cap/Rewarder.sol";
import { BaseTest } from "../../shared/BaseTest.sol";

/// @dev Minimal Lender stand-in exposing only the views the Rewarder reads.
contract MockLenderViews {
    mapping(bytes32 => uint256) public supplyIndex;
    mapping(bytes32 => uint256) public underwriterIndex;
    mapping(bytes32 => uint256) public scaledDebt;

    function setSupplyIndex(bytes32 id, uint256 v) external {
        supplyIndex[id] = v;
    }

    function setUnderwriterIndex(bytes32 id, uint256 v) external {
        underwriterIndex[id] = v;
    }

    function setScaledDebt(bytes32 id, uint256 v) external {
        scaledDebt[id] = v;
    }
}

/// @dev Minimal underwriter tranche stand-in.
contract MockTranche {
    uint256 internal _activeSupply;

    function setActiveSupply(uint256 v) external {
        _activeSupply = v;
    }

    function activeSupply() external view returns (uint256) {
        return _activeSupply;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Unit tests for the Rewarder's premium routing in isolation, using mocks so the
/// "no underwriters" fallback (premium accrues to the supply reward) can be exercised.
contract RewarderUnitTest is BaseTest {
    Rewarder internal rewarder;
    MockLenderViews internal lender;
    MockTranche internal senior;
    MockTranche internal junior;

    bytes32 internal constant MARKET = keccak256("market");

    function setUp() public {
        _setUpAccessManager();
        lender = new MockLenderViews();
        senior = new MockTranche();
        junior = new MockTranche();

        Rewarder impl = new Rewarder();
        rewarder = Rewarder(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Rewarder.initialize, (address(accessManager), address(lender), address(0xCAFE), address(0xBEEF))
                )
            )
        );

        vm.prank(address(lender));
        rewarder.registerMarket(MARKET, address(senior), address(junior));
    }

    function test_updateRewards_bothTranchesEmpty_routesPremiumToSupplyReward() public {
        // both tranches hold no supply but the market carries scaled debt and premium has accrued
        senior.setActiveSupply(0);
        junior.setActiveSupply(0);

        // split premium 50/50 so both the senior and junior legs are non-zero
        vm.prank(address(senior));
        rewarder.setJuniorSplit(MARKET, 0.5e27);

        lender.setScaledDebt(MARKET, 100e18);
        lender.setSupplyIndex(MARKET, 1e27);
        lender.setUnderwriterIndex(MARKET, 2e27); // delta from 0 -> premiumInterest = 200e18

        rewarder.updateRewards(MARKET);

        // with no underwriters, the entire premium falls back onto the supply reward
        assertEq(rewarder.claimableSupplyReward(), 200e18);
        // neither tranche accrued per-share rewards
        assertEq(rewarder.rewardPerShare(MARKET, address(senior)), 0);
        assertEq(rewarder.rewardPerShare(MARKET, address(junior)), 0);
    }
}
