// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { Test, console } from "forge-std/Test.sol";

/// Stateful fuzz for N7: the market OWNER reshuffles / strips tranches and LPs exit what is
/// unlocked, with a fixed loan outstanding and a fixed price. Invariants:
///  W1  owner actions alone never take healthiness below 1e27 (only price can);
///  W2  a tranche outside `tranches()` reads lockedValue == max(0, debt/(lt-buffer) - sum in-array capital)
///      i.e. it is treated as senior to everything and is never in the slash loop;
///  W3  sum of in-array capital * lt >= debt at all times (the owner cannot under-collateralise).
contract WaterfallHandler is Test {
    using WadRayMath for uint256;
    FloatingMarket public market;
    Tranche[3] public tr;
    address[3] public lps;
    address public owner;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public redeemed;
    uint256 public minHealth = type(uint256).max;

    constructor(FloatingMarket m, Tranche[3] memory t, address[3] memory l, address o) {
        market = m;
        tr = t;
        lps = l;
        owner = o;
    }

    function ownerSetTranches(uint8 mask, uint8 seed) external {
        mask = mask % 8;
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (mask & (1 << i) != 0) n++;
        }
        if (n == 0) return;
        IBaseMarket.Tranche[] memory arr = new IBaseMarket.Tranche[](n);
        uint256 k;
        for (uint256 j; j < 3; ++j) {
            uint256 i = (j + seed) % 3; // random order
            if (mask & (1 << i) == 0) continue;
            arr[k] = IBaseMarket.Tranche({ tranche: address(tr[i]), weight: 0 });
            k++;
        }
        uint256 rem = 1e27;
        for (uint256 i; i < n; ++i) {
            arr[i].weight = i + 1 == n ? rem : rem / (n - i);
            rem -= arr[i].weight;
        }
        vm.prank(owner);
        try market.setTranches(arr) {
            accepted++;
        }
            catch {
            rejected++;
        }
        _track();
    }

    function lpRedeem(uint8 who, uint256 shares) external {
        who = who % 3;
        uint256 unlocked = tr[who].unlockedSupply();
        uint256 bal = tr[who].balanceOf(lps[who]);
        uint256 max = unlocked < bal ? unlocked : bal;
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(lps[who]);
        tr[who].redeem(shares, lps[who], lps[who]);
        redeemed += shares;
        _track();
    }

    function _track() internal {
        uint256 h = market.healthiness();
        if (h < minHealth) minHealth = h;
    }
}

contract N3_OwnerWaterfall_Invariants is CapDeployer {
    using WadRayMath for uint256;
    WaterfallHandler h;
    FloatingMarket market;
    Tranche[3] tr;

    function setUp() public {
        _deployCap();
        uint256[] memory w = new uint256[](3);
        w[0] = 0.4e27;
        w[1] = 0.3e27;
        w[2] = 0.3e27;
        (address m, address[] memory ts) = _createMarket("W", defaultMarketOwner, defaultBorrower, w);
        market = FloatingMarket(m);
        _configureMarketRates(market);
        address[3] memory lps = [makeAddr("lp0"), makeAddr("lp1"), makeAddr("lp2")];
        uint256[3] memory amt = [uint256(1_000e18), 600e18, 400e18];
        for (uint256 i; i < 3; ++i) {
            tr[i] = Tranche(ts[i]);
            _fundTranche(ts[i], lps[i], amt[i]);
        }
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 0.5 * 2000 = 1000
        h = new WaterfallHandler(market, tr, lps, defaultMarketOwner);
        targetContract(address(h));
    }

    function invariant_W1_ownerCannotGoBelowOne() public view {
        assertGe(market.healthiness(), 1e27);
    }

    function invariant_W2_removedTrancheIsSeniorToAllAndUnslashable() public view {
        IBaseMarket.Tranche[] memory arr = market.tranches();
        uint256 inArray;
        for (uint256 i; i < arr.length; ++i) {
            inArray += Tranche(arr[i].tranche).totalCapital();
        }
        uint256 floor_ = market.totalDebt().rayDiv(market.lt() - market.buffer());
        for (uint256 i; i < 3; ++i) {
            bool present;
            for (uint256 j; j < arr.length; ++j) {
                if (arr[j].tranche == address(tr[i])) present = true;
            }
            if (present) continue;
            uint256 expected = inArray >= floor_ ? 0 : floor_ - inArray;
            assertEq(market.lockedValue(address(tr[i])), expected, "W2");
        }
    }

    function invariant_W3_inArrayCapitalCoversDebtAtLt() public view {
        assertGe(market.totalCapital().rayMul(market.lt()), market.totalDebt());
    }

    function invariant_report() public view {
        console.log("setTranches accepted / rejected:", h.accepted(), h.rejected());
        console.log("shares redeemed while loan open:", h.redeemed());
        console.log("min healthiness seen (ray):", h.minHealth());
    }
}
