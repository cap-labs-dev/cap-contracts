// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { MathUtils } from "../../../../../contracts/utils/MathUtils.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-6 (E4 / R2 oracle/L-6_IrmBounds). `setLiquiditySlopes`
/// (InterestRateModel.sol:105-115) still only rejects `kink > 1e27` and accrues before writing.
contract R1_L6_IrmBounds is CapDeployer {
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _depositStable(lp, 1_000_000e18);
        _mintStable(makeAddr("b"), 500_000e18);
    }

    function test_H8_unboundedBaseBricksStablecoinAndSetterCannotRecover() public {
        IInterestRateModel.Slopes memory insane =
            IInterestRateModel.Slopes({ base: 1e37, slope0: 0, slope1: 0, kink: 0.8e27 });
        irm.setLiquiditySlopes(insane);
        emit log_named_uint("liquidityRate accepted (ray/yr)", irm.liquidityRate());

        skip(30 days);

        (bool ok,) = address(irm).staticcall(abi.encodeCall(irm.liquidityIndex, ()));
        assertFalse(ok, "liquidityIndex view reverts: index overflow");

        cusdUnderlying.mint(lp, 1e18);
        vm.startPrank(lp);
        cusdUnderlying.approve(address(stablecoin), 1e18);
        (ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.deposit, (1e18, lp)));
        vm.stopPrank();
        assertFalse(ok, "deposit reverts: index overflow");

        (ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.mintCreditBacked, (lp, 1e18)));
        assertFalse(ok, "borrowing (mintCreditBacked) reverts: index overflow");

        IInterestRateModel.Slopes memory sane = capConfig.liquiditySlopes;
        (ok,) = address(irm).call(abi.encodeCall(irm.setLiquiditySlopes, (sane)));
        emit log_named_string("setLiquiditySlopes(sane) after 30d", ok ? "ok" : "REVERTS");
        assertTrue(ok, "setLiquiditySlopes must be able to recover from a bad curve");
    }

    function test_H8_overflowThresholdExceeded() public {
        (bool ok,) = address(this).call(abi.encodeCall(this.compound, (1e37, 30 days)));
        assertFalse(ok, "x = 8.2e8: index.rayMul(3-term expansion) overflows rayMul");
    }

    function compound(uint256 rate, uint256 dt) external pure returns (uint256) {
        return WadRayMath.rayMul(1e27, MathUtils.calculateCompoundedInterest(rate, 0, dt));
    }
}
