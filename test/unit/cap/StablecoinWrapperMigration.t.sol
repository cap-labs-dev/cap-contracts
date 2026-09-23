// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockAeraVault } from "../../shared/mocks/MockAeraVault.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice Upgrade a populated cUSD + wrapper pair and reinitialize both. Balances, vest,
///         escrow and config must survive; the new implementation must still serve users.
/// @dev Live proxies are at Initializable v1. These deploys use `reinitializer(2)`, so the
///      version word is rewound to 1 before the upgrade — the same gate a v1 proxy presents.
contract StablecoinWrapperMigrationTest is BaseTest {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    uint256 private constant PERIOD = 12 hours;
    uint256 private constant PREMIUM = 10e18;

    MockERC20 internal usdc;
    MockIRM internal irm;
    MockAeraVault internal reserve;

    Stablecoin internal scoin;
    Wrapper internal wrapper;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal bobRedeemId;

    struct Snapshot {
        address scoinAuthority;
        address scoinAsset;
        address scoinIrm;
        address scoinReserve;
        address scoinStablecoin;
        uint8 scoinDecimals;
        string scoinName;
        string scoinSymbol;
        uint256 scoinSupply;
        uint256 creditBacked;
        uint256 badDebt;
        uint256 backing;
        uint256 usdcHeld;
        uint256 scoinSelf;
        uint256 aliceCusd;
        uint256 bobCusd;
        uint256 wrapperCusd;
        uint256 staked;
        uint256 queue;
        uint256 bobPending;
        uint256 wrapperClaimable;
        uint256 remaining;
        bool wrapperOptedIn;
        address wrapperAuthority;
        address wrapperAsset;
        string wrapperName;
        string wrapperSymbol;
        uint256 wrapperSupply;
        uint256 aliceStaked;
        uint256 deadShares;
        uint256 wrapperAssets;
    }

    function setUp() public {
        vm.warp(1_000_000);
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();
        reserve = new MockAeraVault();

        scoin = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(reserve), 12 hours)
                )
            )
        );
        wrapper = Wrapper(
            _deployProxy(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(scoin)))
            )
        );

        usdc.mint(alice, 1_000e18);
        usdc.mint(bob, 1_000e18);
        vm.prank(alice);
        usdc.approve(address(scoin), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(scoin), type(uint256).max);
        vm.prank(alice);
        scoin.approve(address(wrapper), type(uint256).max);

        vm.prank(alice);
        scoin.deposit(200e18, alice);
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        vm.prank(bob);
        scoin.deposit(50e18, bob);
        vm.prank(bob);
        bobRedeemId = scoin.requestRedeem(20e18, bob, bob);

        scoin.fundCreditBacked(PREMIUM);
        vm.warp(block.timestamp + 20 * PERIOD);
    }

    function test_migrateStablecoinAndWrapperPreservesLiveState() public {
        Snapshot memory before_ = _snapshot();
        address scoinBefore = _implementation(address(scoin));
        address wrapperBefore = _implementation(address(wrapper));

        _rewindInitializerToV1(address(scoin));
        _rewindInitializerToV1(address(wrapper));

        UUPSUpgradeable(address(scoin))
            .upgradeToAndCall(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(reserve), 12 hours)
                )
            );
        UUPSUpgradeable(address(wrapper))
            .upgradeToAndCall(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(scoin)))
            );

        assertTrue(_implementation(address(scoin)) != scoinBefore, "cUSD implementation moved");
        assertTrue(_implementation(address(wrapper)) != wrapperBefore, "wrapper implementation moved");
        _assertSame(before_, _snapshot());

        // the new impl still serves the live books, and must not spend bob's queued redeem
        uint256 owed = scoin.claimable(address(wrapper));
        assertGt(owed, 0, "the vest is still sitting there");

        vm.prank(alice);
        wrapper.deposit(10e18, alice);

        assertEq(scoin.claimable(address(wrapper)), 0, "the wrapper pulled the vest");
        assertEq(scoin.redemptionQueue(), 20e18, "queued shares were not paid as yield");
        assertEq(scoin.pendingRedeemRequest(bobRedeemId, bob) + scoin.claimableRedeemRequest(bobRedeemId, bob), 20e18);
        assertGe(scoin.balanceOf(address(scoin)), 20e18, "escrow is still here");
        assertLe(scoin.balanceOf(address(scoin)) - 20e18, 0.01e18, "only vest dust sits beside the escrow");

        vm.prank(alice);
        uint256 withdrawn = wrapper.redeem(10e18, alice, alice);
        assertGt(withdrawn, 0);

        vm.prank(alice);
        uint256 minted = scoin.deposit(5e18, alice);
        assertEq(minted, 5e18);

        vm.expectRevert();
        scoin.initialize(
            address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(reserve), 12 hours
        );
        vm.expectRevert();
        wrapper.initialize(address(accessManager), address(scoin));
    }

    function _rewindInitializerToV1(address proxy) private {
        vm.store(proxy, INITIALIZABLE_STORAGE, bytes32(uint256(1)));
    }

    function _snapshot() private view returns (Snapshot memory s) {
        s.scoinAuthority = IAccessManaged(address(scoin)).authority();
        s.scoinAsset = scoin.asset();
        s.scoinIrm = scoin.irm();
        s.scoinReserve = scoin.reserveVault();
        s.scoinStablecoin = scoin.stablecoin();
        s.scoinDecimals = scoin.decimals();
        s.scoinName = scoin.name();
        s.scoinSymbol = scoin.symbol();
        s.scoinSupply = scoin.totalSupply();
        s.creditBacked = scoin.creditBackedSupply();
        s.badDebt = scoin.badDebt();
        s.backing = scoin.backing();
        s.usdcHeld = usdc.balanceOf(address(scoin));
        s.scoinSelf = scoin.balanceOf(address(scoin));
        s.aliceCusd = scoin.balanceOf(alice);
        s.bobCusd = scoin.balanceOf(bob);
        s.wrapperCusd = scoin.balanceOf(address(wrapper));
        s.staked = scoin.stakedSupply();
        s.queue = scoin.redemptionQueue();
        s.bobPending = scoin.pendingRedeemRequest(bobRedeemId, bob) + scoin.claimableRedeemRequest(bobRedeemId, bob);
        s.wrapperClaimable = scoin.claimable(address(wrapper));
        s.remaining = scoin.remaining();
        s.wrapperOptedIn = scoin.optedIn(address(wrapper));
        s.wrapperAuthority = IAccessManaged(address(wrapper)).authority();
        s.wrapperAsset = wrapper.asset();
        s.wrapperName = wrapper.name();
        s.wrapperSymbol = wrapper.symbol();
        s.wrapperSupply = wrapper.totalSupply();
        s.aliceStaked = wrapper.balanceOf(alice);
        s.deadShares = wrapper.balanceOf(DeadShares.HOLDER);
        s.wrapperAssets = wrapper.totalAssets();
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) private pure {
        assertEq(a.scoinAuthority, b.scoinAuthority);
        assertEq(a.scoinAsset, b.scoinAsset);
        assertEq(a.scoinIrm, b.scoinIrm);
        assertEq(a.scoinReserve, b.scoinReserve);
        assertEq(a.scoinStablecoin, b.scoinStablecoin);
        assertEq(a.scoinDecimals, b.scoinDecimals);
        assertEq(a.scoinName, b.scoinName);
        assertEq(a.scoinSymbol, b.scoinSymbol);
        assertEq(a.scoinSupply, b.scoinSupply);
        assertEq(a.creditBacked, b.creditBacked);
        assertEq(a.badDebt, b.badDebt);
        assertEq(a.backing, b.backing);
        assertEq(a.usdcHeld, b.usdcHeld);
        assertEq(a.scoinSelf, b.scoinSelf);
        assertEq(a.aliceCusd, b.aliceCusd);
        assertEq(a.bobCusd, b.bobCusd);
        assertEq(a.wrapperCusd, b.wrapperCusd);
        assertEq(a.staked, b.staked);
        assertEq(a.queue, b.queue);
        assertEq(a.bobPending, b.bobPending);
        assertEq(a.wrapperClaimable, b.wrapperClaimable);
        assertEq(a.remaining, b.remaining);
        assertEq(a.wrapperOptedIn, b.wrapperOptedIn);
        assertEq(a.wrapperAuthority, b.wrapperAuthority);
        assertEq(a.wrapperAsset, b.wrapperAsset);
        assertEq(a.wrapperName, b.wrapperName);
        assertEq(a.wrapperSymbol, b.wrapperSymbol);
        assertEq(a.wrapperSupply, b.wrapperSupply);
        assertEq(a.aliceStaked, b.aliceStaked);
        assertEq(a.deadShares, b.deadShares);
        assertEq(a.wrapperAssets, b.wrapperAssets);
    }

    function _implementation(address proxy) private view returns (address impl) {
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
