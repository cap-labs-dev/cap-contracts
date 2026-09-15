// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-4 (F2/D5): Registry.initialize now validates the seeds
/// (Registry.sol:106-107): `lt > 1e27 || lt <= buffer` -> InvalidLt, `targetHealth < 1.25e27` ->
/// InvalidTargetHealth. The third round-1 case (targetHealth < (1+bonus)*lt) is unreachable at
/// the bounds (lt <= 1, bonus <= 0.1 -> (1+b)*lt <= 1.1 < 1.25).
contract R1_L4_RegistryDefaults is CapDeployer {
    function deployWith(CapConfig memory cfg) external {
        _deployCapWithConfig(cfg);
    }

    function _try(CapConfig memory cfg) internal returns (bool ok, bytes4 sel) {
        bytes memory ret;
        (ok, ret) = address(this).call(abi.encodeCall(this.deployWith, (cfg)));
        if (!ok && ret.length >= 4) sel = bytes4(ret);
    }

    function test_L4_registryRejectsLtEqualBuffer() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.1e27;
        cfg.defaultBuffer = 0.1e27;
        (bool ok, bytes4 sel) = _try(cfg);
        emit log_named_string("deploy with lt == buffer", ok ? "accepted" : "reverted");
        assertFalse(ok, "Registry.initialize accepted lt == buffer");
        assertEq(sel, IBaseMarket.InvalidLt.selector);
    }

    function test_L4_registryRejectsLtAboveOne() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 1e27 + 1;
        (bool ok, bytes4 sel) = _try(cfg);
        assertFalse(ok, "Registry.initialize accepted lt > 1");
        assertEq(sel, IBaseMarket.InvalidLt.selector);
    }

    function test_L4_registryRejectsLowTargetHealth() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultTargetHealth = 1e27;
        (bool ok, bytes4 sel) = _try(cfg);
        emit log_named_string("deploy with targetHealth 1.0", ok ? "accepted" : "reverted");
        assertFalse(ok, "Registry.initialize accepted targetHealth < 1.25");
        assertEq(sel, IBaseMarket.InvalidTargetHealth.selector);
    }

    function test_L4_shippedDefaultsStillDeploy() public {
        (bool ok,) = _try(_defaultCapConfig());
        assertTrue(ok);
    }
}
