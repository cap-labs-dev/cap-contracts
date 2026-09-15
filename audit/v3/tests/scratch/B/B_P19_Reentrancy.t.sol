// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../../../contracts/cap/Vault.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockReentrantERC20 } from "../../../../../test/shared/mocks/MockReentrantERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { console } from "forge-std/console.sol";

/// @notice A liquidation recipient that runs code when the slashed collateral lands. It fires twice
/// per liquidation: once on the junior's payout (senior not yet slashed, market debt still the
/// pre-liquidation figure) and once on the senior's payout. On each it snapshots what the
/// protocol reports and tries every exit it is entitled to as an ordinary third party
/// (senior depositor, junior depositor, underwriter depositor).
contract Probe {
    MockReentrantERC20 public token;
    FloatingMarket public market;
    Tranche public senior;
    Tranche public junior;
    Underwriter public uw;
    Vault public vault;

    struct Snap {
        bool fired;
        uint256 health;
        uint256 debt;
        uint256 maxLiq;
        uint256 seniorUnlocked;
        uint256 seniorInstant;
        uint256 juniorUnlocked;
        bool instantRedeemOk;
        bytes instantRedeemErr;
        bool chargeOk;
        bytes chargeErr;
        bool requestOk;
        uint256 claimableOnFreshRequest;
        bool juniorDepositOk;
        uint256 juniorSharesGot;
        bool uwRedeemOk;
        uint256 uwAssetsGot;
        uint256 uwPricePerShare;
    }

    Snap internal first;
    Snap internal second;
    uint256 internal stage;

    function snap(uint256 i) external view returns (Snap memory) {
        return i == 0 ? first : second;
    }

    constructor(MockReentrantERC20 _t, FloatingMarket _m, Tranche _s, Tranche _j, Underwriter _u, Vault _v) {
        token = _t;
        market = _m;
        senior = _s;
        junior = _j;
        uw = _u;
        vault = _v;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        require(ok, "probe exec failed");
    }

    function poke() external {
        Snap storage s = stage == 0 ? first : second;
        stage++;
        s.fired = true;
        s.health = market.healthiness();
        s.debt = market.totalDebt();
        s.maxLiq = market.maxLiquidatable();
        s.seniorUnlocked = senior.unlockedSupply();
        s.seniorInstant = senior.instantUnlockedSupply();
        s.juniorUnlocked = junior.unlockedSupply();

        // exit the senior mid-waterfall
        try senior.instantRedeem(1e18, address(this), address(this)) {
            s.instantRedeemOk = true;
        }
            catch (bytes memory e) {
            s.instantRedeemErr = e;
        }

        // poke the market itself
        try market.chargePremium() {
            s.chargeOk = true;
        }
            catch (bytes memory e) {
            s.chargeErr = e;
        }

        // queue and see what is claimable right now
        try senior.requestRedeem(1e18, address(this), address(this)) returns (uint256 id) {
            s.requestOk = true;
            s.claimableOnFreshRequest = senior.claimableRedeemRequest(id, address(this));
        } catch { }

        // deposit into the junior after its slash
        try junior.deposit(10e18, address(this)) returns (uint256 sh) {
            s.juniorDepositOk = true;
            s.juniorSharesGot = sh;
        } catch { }

        // underwriter exit at the cached mark
        if (address(uw) != address(0)) {
            s.uwPricePerShare = uw.convertToAssets(1e18);
            uint256 bal = uw.balanceOf(address(this));
            uint256 max = uw.maxInstantRedeem(address(this));
            uint256 shares = bal < max ? bal : max;
            if (shares > 0) {
                try uw.instantRedeem(shares, address(this), address(this)) returns (uint256 a) {
                    s.uwRedeemOk = true;
                    s.uwAssetsGot = a;
                } catch { }
            }
        }

        if (stage == 1) token.arm(address(this), abi.encodeCall(Probe.poke, ()));
    }
}

contract B_P19_Reentrancy is CapDeployer {
    MockReentrantERC20 internal hooked;
    FloatingMarket internal market;
    Tranche internal senior;
    Tranche internal junior;
    Underwriter internal uw;
    Probe internal probe;

    bytes internal guardRevert = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function setUp() public {
        _deployCap();
        hooked = new MockReentrantERC20("Hooked", "hETH", 18);
        _setPrice(address(hooked), 2e18);

        address[] memory assets = new address[](2);
        assets[0] = address(hooked);
        assets[1] = address(hooked);
        (address m, address[] memory tranches) =
            _createMarket("Hooked", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(m);
        senior = Tranche(tranches[0]);
        junior = Tranche(tranches[1]);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(100_000e18);

        _fundTranche(address(senior), address(hooked), makeAddr("seniorLP"), 500e18);
        _fundTranche(address(junior), address(hooked), makeAddr("juniorLP"), 100e18);

        // underwriter on the hooked asset, half allocated to the senior, half idle
        uw = _deployUnderwriterOn(address(hooked));
        uw.addTranche(address(senior));
        _admitDepositor(address(senior), address(uw));
        address uwLP = makeAddr("uwLP");
        hooked.mint(uwLP, 200e18);
        vm.startPrank(uwLP);
        hooked.approve(address(vault), 200e18);
        vault.deposit(address(hooked), 200e18, uwLP);
        vault.setOperator(address(uw), true);
        vm.stopPrank();
        _admitDepositor(address(uw), uwLP);
        vm.prank(uwLP);
        uw.deposit(200e18, uwLP);
        uw.allocate(address(senior), 100e18);

        probe = new Probe(hooked, market, senior, junior, uw, vault);
        // the probe is a senior depositor, a junior depositor, and an underwriter depositor
        hooked.mint(address(probe), 300e18);
        probe.exec(address(hooked), abi.encodeCall(hooked.approve, (address(vault), 300e18)));
        probe.exec(address(vault), abi.encodeCall(vault.deposit, (address(hooked), 300e18, address(probe))));
        probe.exec(address(vault), abi.encodeCall(vault.setOperator, (address(senior), true)));
        probe.exec(address(vault), abi.encodeCall(vault.setOperator, (address(junior), true)));
        probe.exec(address(vault), abi.encodeCall(vault.setOperator, (address(uw), true)));
        _admitDepositor(address(senior), address(probe));
        _admitDepositor(address(junior), address(probe));
        _admitDepositor(address(uw), address(probe));
        probe.exec(address(senior), abi.encodeCall(senior.deposit, (100e18, address(probe))));
        probe.exec(address(uw), abi.encodeCall(uw.deposit, (50e18, address(probe))));

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 700e18);
    }

    function _deployUnderwriterOn(address asset) internal returns (Underwriter u) {
        if (_operatorRoleOf(address(this)) == 0) _assignOperator(address(this));
        uint64 curatorRole = _operatorRoleOf(address(this));
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = address(this);
        uint64[] memory roleIds = registry.createChildRoles(curatorRole, members);
        u = Underwriter(registry.createUnderwriter(asset, "UW", "UW", curatorRole));
        u.setAllocatorRole(roleIds[0]);
        u.setDepositorRole(roleIds[0]);
    }

    function _liquidate(uint256 amount) internal {
        _mintStable(defaultLiquidator, amount);
        hooked.arm(address(probe), abi.encodeCall(Probe.poke, ()));
        vm.prank(defaultLiquidator);
        market.liquidate(address(probe), amount);
    }

    function _log(string memory label, Probe.Snap memory s) internal pure {
        console.log(label);
        console.log("  fired", s.fired);
        console.log("  health", s.health, "debt", s.debt);
        console.log("  maxLiquidatable", s.maxLiq);
        console.log("  senior unlocked", s.seniorUnlocked, "instant", s.seniorInstant);
        console.log("  junior unlocked", s.juniorUnlocked);
        console.log("  senior.instantRedeem ok", s.instantRedeemOk);
        console.log("  market.chargePremium ok", s.chargeOk);
        console.log("  senior.requestRedeem ok", s.requestOk, "claimable", s.claimableOnFreshRequest);
        console.log("  junior.deposit ok", s.juniorDepositOk, "shares", s.juniorSharesGot);
        console.log("  uw.instantRedeem ok", s.uwRedeemOk, "assets", s.uwAssetsGot);
        console.log("  uw price/share mid", s.uwPricePerShare);
    }

    function _snap(bool isFirst) internal view returns (Probe.Snap memory s) {
        s = probe.snap(isFirst ? 0 : 1);
    }

    /// Partial liquidation: market mildly unhealthy, both tranches survive.
    function test_P19_partialLiquidation_recipientCannotExitMidWaterfall() public {
        // 800 tokens at $2 = $1600 vs 700 debt: healthy at lt 0.8, unhealthy at lt 0.35.
        // 300 repaid slashes $306: the $200 junior is emptied and the senior takes the rest,
        // so the hook fires on both payouts.
        market.setLt(0.35e27);
        assertLt(market.healthiness(), 1e27, "must be liquidatable");
        uint256 healthBefore = market.healthiness();
        uint256 uwPriceBefore = uw.convertToAssets(1e18);

        _liquidate(300e18);

        Probe.Snap memory a = _snap(true);
        Probe.Snap memory b = _snap(false);
        _log("after junior payout (senior not yet slashed):", a);
        _log("after senior payout (scaledDebt not yet written):", b);

        assertTrue(a.fired && b.fired, "both hooks fired");
        // mid-flight the market still carries the pre-liquidation debt: health reads LOWER than
        // before the liquidation, never higher, so every exit gate is at least as strict
        assertLe(a.health, healthBefore, "mid-flight health is pessimistic");
        assertLe(b.health, healthBefore, "mid-flight health is pessimistic");
        assertEq(a.seniorUnlocked, 0, "senior fully locked mid-waterfall");
        assertEq(b.seniorUnlocked, 0, "senior fully locked mid-waterfall");
        assertFalse(a.instantRedeemOk, "senior instant exit refused mid-waterfall");
        assertFalse(b.instantRedeemOk, "senior instant exit refused mid-waterfall");
        assertEq(a.claimableOnFreshRequest, 0, "nothing claimable on a fresh queue entry");
        assertEq(a.chargeErr, guardRevert, "market guard holds");
        assertEq(b.chargeErr, guardRevert, "market guard holds");

        // the senior is only reached once the junior is empty, so on this path the junior is
        // already killed when the hook runs and refuses the deposit
        assertFalse(a.juniorDepositOk, "junior killed before the senior is touched");
        assertTrue(junior.killed(), "junior killed");

        // the underwriter exit at the cached mark is the H-1 / P4 lag, made atomic here
        console.log("uw price/share before", uwPriceBefore, "after report", _reportedPrice());
        console.log("uw mid-flight redeem ok", a.uwRedeemOk, "assets", a.uwAssetsGot);
        assertGt(market.healthiness(), 1e27, "post-liquidation healthy");
    }

    function _reportedPrice() internal returns (uint256) {
        uw.report(address(senior));
        return uw.convertToAssets(1e18);
    }

    /// Junior survives (single hook): the mid-flight deposit is priced on the post-slash base.
    function test_P19_juniorSurvives_midFlightDepositGetsNoBargain() public {
        // top the junior up so $306 of slash leaves it alive
        _fundTranche(address(junior), address(hooked), makeAddr("juniorLP2"), 400e18);
        // 1200 tokens = $2400 vs 700 debt: unhealthy at lt 0.25; maxLiquidatable ~276 -> $282 slash
        market.setLt(0.25e27);
        assertLt(market.healthiness(), 1e27, "must be liquidatable");
        uint256 juniorPriceBefore = junior.convertToAssets(1e18);
        _liquidate(300e18);
        Probe.Snap memory a = _snap(true);
        Probe.Snap memory b = _snap(false);
        _log("after junior payout (junior survives):", a);
        assertTrue(a.fired && !b.fired, "single hook: senior untouched");
        assertFalse(junior.killed(), "junior alive");
        assertTrue(a.juniorDepositOk, "junior deposit went through mid-flight");
        uint256 worth = junior.convertToAssets(a.juniorSharesGot);
        console.log("junior price/share before", juniorPriceBefore, "after", junior.convertToAssets(1e18));
        console.log("10e18 deposited mid-flight is worth", worth);
        assertLe(worth, 10e18, "no bargain: priced on the post-slash base");
        assertEq(a.seniorUnlocked, 0, "senior locked");
        assertFalse(a.instantRedeemOk, "senior exit refused");
    }

    /// Full junior wipe: price crash, junior killed on its slash.
    function test_P19_juniorWipe_recipientCannotDepositIntoKilledJunior() public {
        _setPrice(address(hooked), 0.2e18);
        _liquidate(700e18);
        Probe.Snap memory a = _snap(true);
        _log("after junior payout (junior killed):", a);
        assertTrue(a.fired, "fired");
        assertFalse(a.juniorDepositOk, "killed junior refuses the deposit");
        assertTrue(junior.killed(), "junior is killed");
        assertFalse(a.instantRedeemOk, "senior exit refused");
        assertEq(a.chargeErr, guardRevert, "guard");
    }

    /// Hook on Vault.deposit: the collateral hook runs between transferFrom and _mint. The probe
    /// sees its own 6909 balance not yet credited, and any withdraw against it reverts.
    function test_P19_vaultDepositHook_isCEI() public {
        hooked.mint(address(this), 1e18);
        hooked.approve(address(vault), 1e18);
        hooked.arm(address(vault), abi.encodeCall(vault.withdraw, (address(hooked), 1e18, address(this))));
        vault.deposit(address(hooked), 1e18, address(this));
        assertTrue(hooked.reentered(), "hook fired");
        assertFalse(hooked.reentrySucceeded(), "withdraw of the not-yet-minted balance reverts");
        assertEq(vault.balanceOf(address(this), address(hooked)), 1e18, "minted after the transfer");
    }
}
