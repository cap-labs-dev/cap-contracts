// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../../../../contracts/cap/InterestRateModel.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

/// Round-3 re-check of round-1 L-17 (FIXED in round 2): the EMA weight is `1 - retention^elapsed`
/// (InterestRateModel.sol:270-272), so the average after a window does not depend on how many
/// accruals split it.
contract R1_L17_EmaRegime is CapDeployer {
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _depositStable(lp, 1_000_000e18);
        _mintStable(makeAddr("b"), 500_000e18);
    }

    function test_EMA_weightIndependentOfAccrualFrequency() public {
        uint256 period = irm.averagingPeriod();
        for (uint256 i; i < 40; ++i) {
            skip(period);
            irm.updateLiquidityRate();
        }
        (, uint256 s0) = irm.averageSupplies();

        uint256 snap = vm.snapshotState();
        _depositStable(makeAddr("d"), 1_000_000e18);
        skip(period);
        (, uint256 quietSupply) = irm.averageSupplies();
        vm.revertToState(snap);

        _depositStable(makeAddr("d"), 1_000_000e18);
        uint256 steps = period / 12;
        for (uint256 i; i < steps; ++i) {
            skip(12);
            irm.updateLiquidityRate();
        }
        skip(period - steps * 12);
        (, uint256 busySupply) = irm.averageSupplies();

        emit log_named_decimal_uint("avg supply after one period, quiet", quietSupply, 18);
        emit log_named_decimal_uint("avg supply after one period, accrual every 12s", busySupply, 18);
        emit log_named_uint("quiet: % of the way", (quietSupply - s0) * 100 / 1_000_000e18);
        emit log_named_uint("busy:  % of the way", (busySupply - s0) * 100 / 1_000_000e18);
        assertApproxEqRel(
            busySupply,
            quietSupply,
            1e9,
            "one averaging period should weight an observation the same regardless of activity"
        );
    }
}

contract MockStable {
    using WadRayMath for uint256;

    uint256 public credit;
    uint256 public supply;

    function set(uint256 _credit, uint256 _supply) external {
        credit = _credit;
        supply = _supply;
    }

    function supplies() external view returns (uint256, uint256) {
        return (credit, supply);
    }

    function utilizationRate() external view returns (uint256) {
        return supply == 0 ? 0 : credit.rayDiv(supply);
    }
}

contract R1_L17_EmaPathIndependence is Test {
    InterestRateModel internal irm;
    MockStable internal stable;

    function setUp() public {
        vm.warp(1_000_000);
        stable = new MockStable();
        AccessManager am = new AccessManager(address(this));
        irm = InterestRateModel(
            address(
                new ERC1967Proxy(
                    address(new InterestRateModel()),
                    abi.encodeCall(
                        InterestRateModel.initialize, (address(am), address(stable), 1e27, 2e27, 1e27, 0.05e27, 1 hours)
                    )
                )
            )
        );
    }

    function testFuzz_emaPathIndependent(uint256 P, uint256 k, uint256 obs) public {
        P = bound(P, 1, 365 days);
        k = bound(k, 1, 64);
        obs = bound(obs, 1e18, 1e15 * 1e18);
        uint256 credit = obs / 3;

        stable.set(obs / 2, obs);
        irm.updateLiquidityRate();
        skip(3 hours);
        irm.updateLiquidityRate();
        stable.set(credit, obs);
        irm.updateLiquidityRate();

        uint256 snap = vm.snapshotState();
        skip(P);
        (uint256 creditOnce, uint256 supplyOnce) = irm.averageSupplies();
        vm.revertToState(snap);

        uint256 step = P / k;
        uint256 done;
        for (uint256 i; i + 1 < k; ++i) {
            skip(step);
            done += step;
            irm.updateLiquidityRate();
        }
        skip(P - done);
        (uint256 creditK, uint256 supplyK) = irm.averageSupplies();

        _assertPathIndependent(supplyK, supplyOnce, k, "supply average must not depend on accrual path");
        _assertPathIndependent(creditK, creditOnce, k, "credit average must not depend on accrual path");
    }

    function _assertPathIndependent(uint256 a, uint256 b, uint256 k, string memory err) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        if (diff <= k) return;
        assertApproxEqRel(a, b, 1e9, err);
    }
}
