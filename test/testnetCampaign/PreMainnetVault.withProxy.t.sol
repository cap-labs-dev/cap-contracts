// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { LzMessageProxy } from "../../contracts/testnetCampaign/LzMessageProxy.sol";
import { PreMainnetVault } from "../../contracts/testnetCampaign/PreMainnetVault.sol";

import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";

import { L2Token } from "../../contracts/token/L2Token.sol";
import { PermitUtils } from "../deploy/utils/PermitUtils.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";

import { TimeUtils } from "../deploy/utils/TimeUtils.sol";
import { MockVault } from "../mocks/MockVault.sol";
import { MessagingFee, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract PreMainnetVaultWithProxyTest is Test, TestHelperOz5, ProxyUtils, PermitUtils, TimeUtils {
    L2Token public dstOFT;
    PreMainnetVault public vault;
    LzMessageProxy public proxy;
    MockERC20 public asset;
    address public owner; // admin
    address public user; // user not holding yet
    address public l2user; // user not holding yet but on L2
    uint256 public l2userPk;
    address public holder; // user holding
    uint256 public initialBalance;
    uint32 public srcEid = 1;
    uint32 public proxyEid = 2;
    uint32 public dstEid = 3;
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

        // Deploy mock asset        // Deploy mock asset
        asset = new MockERC20("Mock Token", "MTK", 6);
        cap = new MockVault("Mock Cap", "MCAP", 18);
        stakedCap = new MockERC4626(address(cap), 1e18, "Mock Staked Cap", "MSCAP");
        initialBalance = 1000000e6;
        asset.mint(user, initialBalance);
        asset.mint(holder, initialBalance);

        // Initialize mock endpoints
        super.setUp();
        setUpEndpoints(3, LibraryType.SimpleMessageLib);

        // Deploy vault implementation
        vault = new PreMainnetVault(
            address(asset), address(cap), address(stakedCap), endpoints[srcEid], proxyEid, MAX_CAMPAIGN_LENGTH
        );

        // setup proxy
        proxy = LzMessageProxy(
            payable(_deployOApp(type(LzMessageProxy).creationCode, abi.encode(address(endpoints[proxyEid]))))
        );

        // Setup mock dst oapp
        dstOFT = L2Token(
            _deployOApp(type(L2Token).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[dstEid]), owner))
        );
        dstTokenVault = new MockERC4626(address(dstOFT), 1e18, "Mock Token Vault", "MTKV");

        // Wire OApps
        address[] memory oapps = new address[](2);
        oapps[0] = address(vault);
        oapps[1] = address(proxy);
        this.wireOApps(oapps);
        oapps[0] = address(proxy);
        oapps[1] = address(dstOFT);
        this.wireOApps(oapps);

        // Give user some ETH for LZ fees
        vm.deal(user, 100 ether);
        vm.deal(l2user, 100 ether);
        vm.deal(holder, 100 ether);

        // the proxy needs some gas as well
        vm.deal(address(proxy), 100 ether);

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

    function test_deposit_bridges_to_l2_with_proxy_and_back_bridges_disabled() public {
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

        // Verify that the proxy operation was successful
        _timeTravel(100);
        verifyPackets(proxyEid, addressToBytes32(address(proxy)));

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
    }

    function test_setLzReceiveGas() public {
        assertEq(vault.lzReceiveGas(), 400_000);

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

    // allow vm.expectRevert() on verifyPackets
    function externalVerifyPackets(uint32 _eid, bytes32 _to) external {
        verifyPackets(_eid, _to);
    }

    function convertFrom6DecimalTo18Decimal(uint256 _amount) public pure returns (uint256) {
        return _amount * 1e18 / 1e6;
    }
}
