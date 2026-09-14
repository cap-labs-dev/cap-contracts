// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PremiumVesting } from "../../../../contracts/utils/PremiumVesting.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Test } from "forge-std/Test.sol";

contract VestingHarness is PremiumVesting {
    function _transferIn(address, uint256) internal override { }
    function _transferOut(address, uint256) internal override { }

    function totalAssets() public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    function initialize(IERC20 asset, address premium) external initializer {
        __PremiumVesting_init(asset, "Vault", "VLT", premium);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function fund(uint256 amount) external {
        _fund(amount);
    }
}

/// @notice Kills Gambit `PremiumVesting#55` (`if (!optedIn[msg.sender]) return;` dropped in
/// {optOut}). The stock no-op test opts out an account with a zero balance, so `staked -= 0` hides
/// it. A holder that never opted in could otherwise subtract its balance from the opted-in supply,
/// inflating every earner's per-share slice — or underflow it and freeze opt-outs entirely.
contract VestingOptOutKillTest is Test {
    VestingHarness internal v;
    MockERC20 internal premium;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        premium = new MockERC20("Cap USD", "cUSD", 18);
        v = new VestingHarness();
        v.initialize(IERC20(address(new MockERC20("Collateral", "COL", 18))), address(premium));
        v.mint(alice, 100e18);
        vm.prank(alice);
        v.optIn();
        v.mint(bob, 50e18);
    }

    function test_optOutByANonEarnerWithABalanceChangesNothing() public {
        assertEq(v.stakedSupply(), 100e18, "only alice earns");
        assertFalse(v.optedIn(bob));

        vm.prank(bob);
        v.optOut();

        assertEq(v.stakedSupply(), 100e18, "bob was never in, so nothing leaves the staked supply");
        assertFalse(v.optedIn(bob));

        premium.mint(address(v), 10e18);
        v.fund(10e18);
        vm.warp(block.timestamp + 20 * v.vestingPeriod());
        assertApproxEqRel(v.claimable(alice), 10e18, 1e12, "alice's slice is undiluted and unexaggerated");
        assertEq(v.claimable(bob), 0);
    }

    function test_optOutByANonEarnerLargerThanTheStakedSupplyDoesNotRevert() public {
        v.mint(bob, 100e18); // bob now holds more than the whole opted-in supply
        vm.prank(bob);
        v.optOut();
        assertEq(v.stakedSupply(), 100e18);
    }
}
