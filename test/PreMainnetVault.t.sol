// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { PreMainnetVault } from "../contracts/testnetCampaign/PreMainnetVault.sol";

import { ProxyUtils } from "../contracts/deploy/utils/ProxyUtils.sol";

import { L2Token } from "../contracts/token/L2Token.sol";
import { PermitUtils } from "./deploy/utils/PermitUtils.sol";

import { TimeUtils } from "./deploy/utils/TimeUtils.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockVault } from "./mocks/MockVault.sol";
import { MessagingFee, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract PreMainnetVaultTest is Test, TestHelperOz5, ProxyUtils, PermitUtils, TimeUtils {
    L2Token public dstOFT;
    PreMainnetVault public vault;
    MockERC20 public asset;
    address public owner; // admin
    address public user; // user not holding yet
    address public l2user; // user not holding yet but on L2
    uint256 public l2userPk;
    address public holder; // user holding
    uint256 public initialBalance;
    uint32 public srcEid = 1;
    uint32 public dstEid = 2;
    uint48 public constant MAX_CAMPAIGN_LENGTH = 7 days;
    MockERC4626 public dstTokenVault;
    MockVault public cap;
    MockERC4626 public stakedCap;

    function setUp() public override {
        // initialize users
        owner = address(this);
        user = makeAddr("user");
        (l2user, l2userPk) = makeAddrAndKey("l2user");
        holder = makeAddr("holder");

        // Deploy mock asset
        asset = new MockERC20("Mock Token", "MTK", 6);
        cap = new MockVault("Mock Cap", "MCAP", 18);
        stakedCap = new MockERC4626(address(cap), 1e18, "Mock Staked Cap", "MSCAP");
        initialBalance = 1000000e6;
        asset.mint(user, initialBalance);
        asset.mint(holder, initialBalance);

        // Initialize mock endpoints
        super.setUp();
        setUpEndpoints(2, LibraryType.SimpleMessageLib);

        // Deploy vault implementation
        vault = new PreMainnetVault(
            address(asset), address(cap), address(stakedCap), endpoints[srcEid], dstEid, MAX_CAMPAIGN_LENGTH
        );

        // Setup mock dst oapp
        dstOFT = L2Token(
            _deployOApp(type(L2Token).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[dstEid]), owner))
        );
        dstTokenVault = new MockERC4626(address(dstOFT), 1e18, "Mock Token Vault", "MTKV");

        // Wire OApps
        address[] memory oapps = new address[](2);
        oapps[0] = address(vault);
        oapps[1] = address(dstOFT);
        this.wireOApps(oapps);

        // Give user some ETH for LZ fees
        vm.deal(user, 100 ether);
        vm.deal(l2user, 100 ether);
        vm.deal(holder, 100 ether);

        // make a holder hold some vault tokens
        {
            vm.startPrank(holder);

            asset.approve(address(vault), initialBalance);
            MessagingFee memory fee = vault.quote(initialBalance, holder);
            vault.deposit{ value: fee.nativeFee }(
                initialBalance, convertFrom6DecimalTo18Decimal(initialBalance), holder, holder, block.timestamp
            );

            vm.stopPrank();
        }
    }

    function test_decimals_match_asset() public view {
        assertEq(vault.decimals(), asset.decimals());
        assertEq(vault.sharedDecimals(), 6); // Default shared decimals
    }

    function test_deposit_bridges_to_l2_and_back() public {
        uint256 amount = 100e6;
        vm.startPrank(user);

        // Approve vault to spend tokens
        asset.approve(address(vault), amount);

        // quote fees to get some
        MessagingFee memory fee = vault.quote(amount, user);

        // Expect Deposit event
        vm.expectEmit(true, true, true, true);
        emit PreMainnetVault.Deposit(user, amount, convertFrom6DecimalTo18Decimal(amount));

        // Deposit with some ETH for LZ fees
        vault.deposit{ value: fee.nativeFee }(
            amount, convertFrom6DecimalTo18Decimal(amount), l2user, user, block.timestamp
        );

        assertEq(vault.balanceOf(user), convertFrom6DecimalTo18Decimal(amount));
        assertEq(stakedCap.balanceOf(address(vault)), convertFrom6DecimalTo18Decimal(initialBalance + amount));
        assertEq(asset.balanceOf(user), initialBalance - amount);

        // Verify that the dst operation was successful
        _timeTravel(100);
        verifyPackets(dstEid, addressToBytes32(address(dstOFT)));
        assertEq(dstOFT.balanceOf(l2user), convertFrom6DecimalTo18Decimal(amount));

        // Generate permit signature
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(
            l2user, l2userPk, address(dstTokenVault), convertFrom6DecimalTo18Decimal(amount), deadline, address(dstOFT)
        );

        // we can permit2 approve dstOFT
        dstOFT.permit(l2user, address(dstTokenVault), convertFrom6DecimalTo18Decimal(amount), deadline, v, r, s);

        {
            vm.startPrank(l2user);
            dstTokenVault.deposit(convertFrom6DecimalTo18Decimal(amount), l2user);
            vm.stopPrank();
        }
        assertEq(dstOFT.balanceOf(address(dstTokenVault)), convertFrom6DecimalTo18Decimal(amount));
        assertEq(dstOFT.balanceOf(l2user), 0);

        // and we can withdraw dstOFT from the vault
        {
            vm.startPrank(l2user);
            dstTokenVault.withdraw(convertFrom6DecimalTo18Decimal(amount), l2user, l2user);
            vm.stopPrank();
        }
        assertEq(dstOFT.balanceOf(l2user), convertFrom6DecimalTo18Decimal(amount));

        // and we CANNOT bridge back to L1
        /* {
            vm.startPrank(l2user);
            SendParam memory sendParam = SendParam({
                dstEid: srcEid,
                to: addressToBytes32(address(user)),
                amountLD: convertFrom6DecimalTo18Decimal(amount),
                minAmountLD: convertFrom6DecimalTo18Decimal(amount),
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            });
            fee = dstOFT.quoteSend(sendParam, false);
            dstOFT.send{ value: fee.nativeFee }(sendParam, fee, user /* refund address */
        /*);

            _timeTravel(100);
            vm.expectRevert();
            this.externalVerifyPackets(srcEid, addressToBytes32(address(vault)));

            // verify that our balances are unchanged
            assertEq(vault.balanceOf(user), amount);
            assertEq(stakedCap.balanceOf(address(vault)), convertFrom6DecimalTo18Decimal(initialBalance + amount));
            assertEq(asset.balanceOf(user), initialBalance - amount);

            // the l2user did send the tokens to the dstOFT
            assertEq(dstOFT.balanceOf(l2user), 0);

            vm.stopPrank();
        }*/
    }

    function test_revert_deposit_zero_amount() public {
        vm.startPrank(user);

        asset.approve(address(vault), 1);

        MessagingFee memory fee = vault.quote(1, user);

        vm.expectRevert(PreMainnetVault.ZeroAmount.selector);
        vault.deposit{ value: fee.nativeFee }(0, 0, user, user, block.timestamp);

        vm.stopPrank();
    }

    function test_revert_deposit_not_enough_native_tokens() public {
        vm.startPrank(user);

        uint256 amount = 100e18;

        asset.approve(address(vault), amount);

        MessagingFee memory fee = vault.quote(amount, user);

        vm.expectRevert();
        vault.deposit{ value: fee.nativeFee - 1 }(
            amount, convertFrom6DecimalTo18Decimal(amount), user, user, block.timestamp
        );

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
            emit PreMainnetVault.TransferEnabled();
            vault.enableTransfer();

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance));
        assertEq(vault.balanceOf(l2user), 0);

        // Now withdrawals should work
        uint256 amount = 10e6;
        {
            vm.startPrank(holder);

            vault.transfer(l2user, amount);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance) - amount);
        assertEq(vault.balanceOf(l2user), amount);
    }

    function test_admin_can_enable_withdrawals_before_campaign_end() public {
        // Only owner can enable withdrawals
        {
            vm.startPrank(owner);

            vm.expectEmit(false, false, false, true);
            emit PreMainnetVault.TransferEnabled();
            vault.enableTransfer();

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance));
        assertEq(asset.balanceOf(holder), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.withdraw(amount, holder);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance) - amount);
        assertEq(stakedCap.balanceOf(holder), amount);
    }

    function test_transfer_after_campaign_end() public {
        // Fast forward past campaign end
        vm.warp(block.timestamp + MAX_CAMPAIGN_LENGTH + 1);

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance));
        assertEq(vault.balanceOf(l2user), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.transfer(l2user, amount);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance) - amount);
        assertEq(vault.balanceOf(l2user), amount);
    }

    function test_withdraw_after_campaign_end() public {
        // Fast forward past campaign end
        vm.warp(block.timestamp + MAX_CAMPAIGN_LENGTH + 1);

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance));
        assertEq(stakedCap.balanceOf(holder), 0);

        // Now withdrawals should work
        uint256 amount = 10e18;
        {
            vm.startPrank(holder);

            vault.withdraw(amount, holder);

            vm.stopPrank();
        }

        assertEq(vault.balanceOf(holder), convertFrom6DecimalTo18Decimal(initialBalance) - amount);
        assertEq(stakedCap.balanceOf(holder), amount);
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

    function test_setLzReceiveGas() public {
        assertEq(vault.lzReceiveGas(), 100_000);

        vm.startPrank(owner);
        vault.setLzReceiveGas(200_000);
        vm.stopPrank();

        assertEq(vault.lzReceiveGas(), 200_000);

        vm.startPrank(user);
        vm.expectRevert();
        vault.setLzReceiveGas(300_000);
        vm.stopPrank();

        assertEq(vault.lzReceiveGas(), 200_000);
    }

    function test_revert_deposit_or_withdraw_zero_address_or_amount() public {
        vm.startPrank(user);

        asset.approve(address(vault), 1);

        MessagingFee memory fee = vault.quote(1, address(0));

        vm.expectRevert(PreMainnetVault.ZeroAddress.selector);
        vault.deposit{ value: fee.nativeFee }(
            1, convertFrom6DecimalTo18Decimal(1), address(0), address(0), block.timestamp
        );

        vm.expectRevert(PreMainnetVault.ZeroAmount.selector);
        vault.deposit{ value: fee.nativeFee }(
            0, convertFrom6DecimalTo18Decimal(0), address(0), address(0), block.timestamp
        );

        vm.expectRevert(PreMainnetVault.ZeroAddress.selector);
        vault.withdraw(1, address(0));

        vm.expectRevert(PreMainnetVault.ZeroAmount.selector);
        vault.withdraw(0, address(0));

        vm.stopPrank();
    }

    // allow vm.expectRevert() on verifyPackets
    function externalVerifyPackets(uint32 _eid, bytes32 _to) external {
        verifyPackets(_eid, _to);
    }

    function convertFrom6DecimalTo18Decimal(uint256 _amount) public pure returns (uint256) {
        return _amount * 1e18 / 1e6;
    }
}
