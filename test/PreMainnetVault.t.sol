// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PreMainnetVault } from "../contracts/testnetCampaign/PreMainnetVault.sol";

import { L2Token } from "../contracts/token/L2Token.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract PreMainnetVaultTest is Test, TestHelperOz5 {
    L2Token public dstOFT;
    PreMainnetVault public vault;
    MockERC20 public asset;
    address public owner;
    address public user;
    address public holder;
    address public recipient;
    uint256 public initialBalance;
    uint32 public srcEid = 1;
    uint32 public dstEid = 2;
    uint48 public constant MAX_CAMPAIGN_LENGTH = 7 days;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event TransferEnabled();

    function setUp() public override {
        // initialize users
        owner = address(this);
        user = makeAddr("user");
        recipient = makeAddr("recipient");
        holder = makeAddr("holder");

        // Deploy mock asset
        asset = new MockERC20("Mock Token", "MTK");
        initialBalance = 1000000e18;
        asset.mint(user, initialBalance);
        asset.mint(holder, initialBalance);

        // Initialize mock endpoints
        super.setUp();
        setUpEndpoints(2, LibraryType.SimpleMessageLib);

        // Deploy vault implementation
        vault = new PreMainnetVault(endpoints[srcEid]);
        vault.initialize(dstEid, address(asset), MAX_CAMPAIGN_LENGTH);

        // Setup mock dst oapp
        dstOFT = L2Token(
            _deployOApp(type(L2Token).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[dstEid]), owner))
        );

        // Wire OApps
        address[] memory oapps = new address[](2);
        oapps[0] = address(vault);
        oapps[1] = address(dstOFT);
        this.wireOApps(oapps);

        // Give user some ETH for LZ fees
        vm.deal(user, 100 ether);
        vm.deal(holder, 100 ether);

        // make a holder hold some vault tokens
        {
            vm.startPrank(holder);

            asset.approve(address(vault), initialBalance);
            MessagingFee memory fee = vault.quoteDeposit(initialBalance, holder);
            vault.deposit{ value: fee.nativeFee }(initialBalance, holder);

            vm.stopPrank();
        }
    }

    function test_decimals_match_asset() public view {
        assertEq(vault.decimals(), asset.decimals());
        assertEq(vault.sharedDecimals(), 6); // Default shared decimals
    }

    function test_deposit_success() public {
        uint256 amount = 100e18;
        vm.startPrank(user);

        // Approve vault to spend tokens
        asset.approve(address(vault), amount);

        // quote fees to get some
        MessagingFee memory fee = vault.quoteDeposit(amount, user);

        // Expect Deposit event
        vm.expectEmit(true, true, true, true);
        emit Deposit(user, amount);

        // Deposit with some ETH for LZ fees
        vault.deposit{ value: fee.nativeFee }(amount, recipient);

        assertEq(vault.balanceOf(user), amount);
        assertEq(asset.balanceOf(address(vault)), initialBalance + amount);
        assertEq(asset.balanceOf(user), initialBalance - amount);

        // Verify that the dst operation was successful
        verifyPackets(dstEid, addressToBytes32(address(dstOFT)));
        assertEq(dstOFT.balanceOf(recipient), amount);

        vm.stopPrank();
    }

    function test_revert_deposit_zero_amount() public {
        vm.startPrank(user);

        asset.approve(address(vault), 1);

        MessagingFee memory fee = vault.quoteDeposit(1, user);

        vm.expectRevert(PreMainnetVault.ZeroAmount.selector);
        vault.deposit{ value: fee.nativeFee }(0, user);

        vm.stopPrank();
    }

    function test_revert_deposit_not_enough_native_tokens() public {
        vm.startPrank(user);

        uint256 amount = 100e18;

        asset.approve(address(vault), amount);

        MessagingFee memory fee = vault.quoteDeposit(amount, user);

        vm.expectRevert();
        vault.deposit{ value: fee.nativeFee - 1 }(amount, user);

        vm.stopPrank();
    }

    function test_withdraw_restriction() public {
        uint256 amount = 100e18;

        // Try to transfer before campaign ends
        {
            vm.startPrank(holder);
            vm.expectRevert(PreMainnetVault.TransferNotEnabled.selector);
            vault.transfer(holder, amount);
            vm.stopPrank();
        }

        // try withdrawing before campaign ends
        {
            vm.startPrank(holder);
            vm.expectRevert(PreMainnetVault.TransferNotEnabled.selector);
            vault.withdraw(amount, holder);
            vm.stopPrank();
        }
    }

    function test_admin_can_enable_transfers_before_campaign_end() public {
        // Only owner can enable transfers
        {
            vm.startPrank(owner);

            vm.expectEmit(false, false, false, true);
            emit TransferEnabled();
            vault.enableTransfer();

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance);
        assertEq(vault.balanceOf(recipient), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.transfer(recipient, amount);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance - amount);
        assertEq(vault.balanceOf(recipient), amount);
    }

    function test_admin_can_enable_withdrawals_before_campaign_end() public {
        // Only owner can enable withdrawals
        {
            vm.startPrank(owner);

            vm.expectEmit(false, false, false, true);
            emit TransferEnabled();
            vault.enableTransfer();

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance);
        assertEq(asset.balanceOf(holder), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.withdraw(amount, holder);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance - amount);
        assertEq(asset.balanceOf(holder), amount);
    }

    function test_transfer_after_campaign_end() public {
        // Fast forward past campaign end
        vm.warp(block.timestamp + MAX_CAMPAIGN_LENGTH + 1);

        assertEq(vault.balanceOf(holder), initialBalance);
        assertEq(vault.balanceOf(recipient), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.transfer(recipient, amount);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance - amount);
        assertEq(vault.balanceOf(recipient), amount);
    }

    function test_withdraw_after_campaign_end() public {
        // Fast forward past campaign end
        vm.warp(block.timestamp + MAX_CAMPAIGN_LENGTH + 1);

        assertEq(vault.balanceOf(holder), initialBalance);
        assertEq(asset.balanceOf(holder), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.withdraw(amount, holder);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), initialBalance - amount);
        assertEq(asset.balanceOf(holder), amount);
    }

    function test_ownership_transfer_also_sets_lz_delegate() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        // Check new owner
        assertEq(vault.owner(), newOwner);

        // only the new owner is allowed to set delegate
        {
            vm.startPrank(newOwner);

            vault.setDelegate(owner);

            vm.stopPrank();
        }
    }
}
