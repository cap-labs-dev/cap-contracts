// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../test/shared/mocks/MockIRM.sol";
import { LossyAeraVault } from "./LossyAeraVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

/// @notice Drives every reserve-touching path. All roles are held by the handler (ADMIN_ROLE).
contract N2Handler is Test {
    Stablecoin public sc;
    MockERC20 public asset;
    LossyAeraVault public aera;
    address public borrower = makeAddr("borrower");
    address[] public actors;
    mapping(address => uint256[]) internal requests;

    uint256 public ghostLoss; // assets Aera destroyed
    uint256 public instantReverts; // redeem(maxRedeem-bounded) that reverted
    uint256 public claimReverts; // claim(claimable) that reverted
    uint256 public instantOk;
    uint256 public claimOk;
    uint256 public calls;

    constructor(Stablecoin _sc, MockERC20 _asset, LossyAeraVault _aera) {
        sc = _sc;
        asset = _asset;
        aera = _aera;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(a);
            vm.prank(a);
            asset.approve(address(sc), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 1_000_000e18);
        address a = _actor(seed);
        asset.mint(a, amount);
        vm.prank(a);
        sc.deposit(amount, a);
    }

    function redeemInstant(uint256 seed, uint256 shares) external {
        calls++;
        address a = _actor(seed);
        uint256 max = sc.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(a);
        try sc.redeem(shares, a, a) {
            instantOk++;
        } catch {
            instantReverts++;
        }
    }

    function requestRedeem(uint256 seed, uint256 shares) external {
        calls++;
        address a = _actor(seed);
        uint256 bal = sc.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        uint256 id = sc.requestRedeem(shares, a, a);
        requests[a].push(id);
    }

    function claim(uint256 seed, uint256 idx) external {
        calls++;
        address a = _actor(seed);
        uint256[] storage ids = requests[a];
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        uint256 claimable = sc.claimableRedeemRequest(id, a);
        if (claimable == 0) return;
        vm.prank(a);
        try sc.redeem(id, claimable, a, a) {
            claimOk++;
        } catch {
            claimReverts++;
        }
    }

    function borrow(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 1_000_000e18);
        sc.mintCreditBacked(borrower, amount);
    }

    function repay(uint256 amount) external {
        calls++;
        uint256 max = sc.creditBackedSupply();
        uint256 bal = sc.balanceOf(borrower);
        if (max > bal) max = bal;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        sc.burnCreditBacked(borrower, amount);
    }

    function writeOff(uint256 amount) external {
        calls++;
        uint256 max = sc.creditBackedSupply();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        sc.recognizeBadDebt(amount);
    }

    function coverBadDebt(uint256 seed, uint256 amount) external {
        calls++;
        if (sc.badDebt() == 0) return;
        address a = _actor(seed);
        uint256 bal = sc.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        sc.coverBadDebt(amount);
    }

    function fund(uint256 seed, uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 100_000e18);
        address a = _actor(seed);
        asset.mint(a, amount);
        vm.prank(a);
        sc.fund(amount);
    }

    function invest(uint256 amount) external {
        calls++;
        uint256 liquid = asset.balanceOf(address(sc));
        if (liquid == 0) return;
        amount = bound(amount, 1, liquid);
        sc.invest(amount);
    }

    function recall(uint256 amount) external {
        calls++;
        uint256 held = asset.balanceOf(address(aera));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        sc.recall(amount);
    }

    function aeraLose(uint256 bps) external {
        calls++;
        bps = bound(bps, 1, 5_000);
        ghostLoss += aera.lose(IERC20(address(asset)), bps);
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }
}

abstract contract N2InvariantBase is BaseTest {
    Stablecoin internal sc;
    MockERC20 internal asset;
    MockIRM internal irm;
    LossyAeraVault internal aera;
    N2Handler internal h;

    function _setUpN2(bool withLoss) internal {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();
        aera = new LossyAeraVault();
        Stablecoin impl = new Stablecoin();
        sc = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(asset), "Cap USD", "cUSD", "", address(irm), address(aera))
                )
            )
        );
        h = new N2Handler(sc, asset, aera);
        accessManager.grantRole(accessManager.ADMIN_ROLE(), address(h), 0); // MARKET + KEEPER surface

        bytes4[] memory sel = new bytes4[](withLoss ? 14 : 13);
        sel[0] = h.deposit.selector;
        sel[1] = h.redeemInstant.selector;
        sel[2] = h.requestRedeem.selector;
        sel[3] = h.claim.selector;
        sel[4] = h.borrow.selector;
        sel[5] = h.repay.selector;
        sel[6] = h.writeOff.selector;
        sel[7] = h.coverBadDebt.selector;
        sel[8] = h.fund.selector;
        sel[9] = h.invest.selector;
        sel[10] = h.recall.selector;
        sel[11] = h.warp.selector;
        sel[12] = h.deposit.selector; // weight deposits up so the reserve is non-trivial
        if (withLoss) sel[13] = h.aeraLose.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        targetContract(address(h));
    }

    function _held() internal view returns (uint256) {
        return asset.balanceOf(address(sc)) + asset.balanceOf(address(aera));
    }
}

/// @notice I1 restated for the invested state, no strategy loss.
contract N2NoLossInvariants is N2InvariantBase {
    function setUp() public {
        _setUpN2(false);
    }

    /// I1' : liquid + invested == unlockedSupply (18-dp asset) through every path.
    function invariant_I1_reserveIdentityWithAeraGhost() public view {
        assertEq(_held(), sc.unlockedSupply(), "liquid + aeraHeld != unlockedSupply");
        assertEq(sc.badDebt() + sc.creditBackedSupply() + sc.unlockedSupply(), sc.totalSupply(), "supply split");
    }

    /// Liquid balance alone is what redemptions can actually draw on.
    function invariant_liquidCoversOnlyPartOfUnlocked() public view {
        assertLe(asset.balanceOf(address(sc)), sc.unlockedSupply());
    }
}

/// @notice With Aera losses: the gap between promise and holdings equals the loss, exactly, and
/// nothing in the Stablecoin ever books it.
contract N2LossInvariants is N2InvariantBase {
    function setUp() public {
        _setUpN2(true);
    }

    function invariant_lossGapEqualsGhostLoss_neverRecognised() public view {
        uint256 promised = sc.unlockedSupply();
        uint256 held = _held();
        assertEq(promised, held + h.ghostLoss(), "gap != ghostLoss");
        // totalAssets overstates backing by exactly the unbooked loss
        assertEq(sc.totalAssets(), held + h.ghostLoss() + sc.creditBackedSupply(), "totalAssets ignores loss");
    }

    /// Every promise is still nominally issued at par: the shortfall is not spread, it waits for
    /// whoever redeems last.
    function invariant_sharePriceStillParDespiteLoss() public view {
        if (sc.badDebt() == 0 && sc.totalSupply() > 0) {
            assertEq(sc.previewRedeem(1e18), 1e18, "no haircut for reserve loss");
        }
    }
}

/// @notice maxRedeem must be redeemable (ERC-4626 MUST). Expected to FAIL once invest() runs.
contract N2MaxRedeemInvariants is N2InvariantBase {
    function setUp() public {
        _setUpN2(false);
    }

    function invariant_maxRedeemIsActuallyRedeemable() public {
        uint256 n = h.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = h.actors(i);
            uint256 max = sc.maxRedeem(a);
            if (max == 0) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(a);
            (bool ok,) = address(sc).call(abi.encodeWithSignature("redeem(uint256,address,address)", max, a, a));
            vm.revertToState(snap);
            if (!ok) {
                emit log_named_uint("maxRedeem", max);
                emit log_named_uint("liquid", asset.balanceOf(address(sc)));
                emit log_named_uint("invested", asset.balanceOf(address(aera)));
            }
            assertTrue(ok, "redeem(maxRedeem) reverted");
        }
    }
}
