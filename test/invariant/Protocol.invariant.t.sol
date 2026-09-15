// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ProtocolHandler } from "./handlers/ProtocolHandler.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

contract ProtocolInvariantTest is StdInvariant, Test {
    ProtocolHandler internal handler;
    bytes4[] internal selectors;
    uint256[4][] internal bootstrap;

    function setUp() public virtual {
        handler = new ProtocolHandler();
        selectors.push(handler.reserveDeposit.selector);
        selectors.push(handler.custody.selector);
        selectors.push(handler.deposit.selector);
        selectors.push(handler.transferShares.selector);
        selectors.push(handler.wrap.selector);
        selectors.push(handler.invest.selector);
        selectors.push(handler.allocate.selector);
        selectors.push(handler.deallocate.selector);
        selectors.push(handler.finalize.selector);
        selectors.push(handler.report.selector);
        selectors.push(handler.borrow.selector);
        selectors.push(handler.repay.selector);
        selectors.push(handler.extend.selector);
        selectors.push(handler.advance.selector);
        selectors.push(handler.price.selector);
        selectors.push(handler.risk.selector);
        selectors.push(handler.charge.selector);
        selectors.push(handler.liquidate.selector);
        selectors.push(handler.writeOff.selector);
        selectors.push(handler.cover.selector);
        selectors.push(handler.premium.selector);
        selectors.push(handler.request.selector);
        selectors.push(handler.transferRequest.selector);
        selectors.push(handler.settle.selector);
        selectors.push(handler.permission.selector);
        selectors.push(handler.unauthorized.selector);
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));

        // A checked, explicit bootstrap ensures every run starts beyond the debt-free state.
        // Later handler calls remain random; bootstrap coverage is reported separately.
        handler.borrow(1, false, 1 days);
        handler.borrow(1, true, 1 days);
        handler.checkAccounting();
        _snapshotBootstrap();
    }

    function invariant_closedSystemAccounting() public view {
        handler.checkAccounting();
    }

    function afterInvariant() public {
        handler.checkAccounting();
        string memory metrics = string.concat(
            '{"seed":"',
            vm.envOr("FOUNDRY_FUZZ_SEED", string("unrecorded")),
            '","profile":"',
            vm.envOr("FOUNDRY_PROFILE", string("default")),
            '","sequence":"',
            vm.toString(handler.sequenceHash()),
            '","operations":{'
        );
        for (uint256 i; i < selectors.length; ++i) {
            (uint256 attempts, uint256 successes, uint256 skips, uint256 expected) = handler.calls(selectors[i]);
            assertEq(attempts, successes + skips + expected, "operation counter partition");
            metrics = string.concat(
                metrics,
                i == 0 ? "" : ",",
                '"',
                vm.toString(abi.encodePacked(selectors[i])),
                '":[',
                vm.toString(attempts - bootstrap[i][0]),
                ",",
                vm.toString(successes - bootstrap[i][1]),
                ",",
                vm.toString(skips - bootstrap[i][2]),
                ",",
                vm.toString(expected - bootstrap[i][3]),
                "]"
            );
        }
        handler.unwind();
        handler.checkAccounting();
        // One append per completed sequence, not just Forge's attempts-only selector table.
        vm.createDir("artifacts/fuzz-and-invariant-tests", true);
        vm.writeLine(_metricsPath(), string.concat(metrics, "}}"));
    }

    function _metricsPath() internal pure virtual returns (string memory) {
        return "artifacts/fuzz-and-invariant-tests/healthy-metrics.jsonl";
    }

    function _snapshotBootstrap() internal {
        delete bootstrap;
        for (uint256 i; i < selectors.length; ++i) {
            (uint256 a, uint256 s, uint256 k, uint256 e) = handler.calls(selectors[i]);
            bootstrap.push([a, s, k, e]);
        }
    }

    function test_checkedLifecycleReachesLossPartialClaimAndUnwind() public {
        _exerciseLossScenario();
        handler.unwind();
        handler.checkAccounting();
        assertEq(handler.unwinds(), 1);
    }

    function _exerciseLossScenario() internal {
        handler.request(1, 0, 1);
        handler.settle(1, 0, 3, 2);
        handler.deallocate(0, 1, true);
        handler.advance(1 days);
        handler.charge();
        handler.advance(1 days);
        handler.premium(0, 0, 3, 1);
        handler.checkAccounting();
        handler.price(1);
        handler.writeOff(0, false);
        handler.checkAccounting();
        handler.liquidate(0, 100e18 + 3, false);
        handler.checkAccounting();
        handler.cover(1);
        handler.finalize(1, 3);
        handler.report(0);
        handler.checkAccounting();
        assertGt(handler.partialSettlements(), 0);
        assertGt(handler.lossActions(), 0);
        assertGt(handler.positiveClaims(), 0);
    }
}

/// @notice Every sequence starts with a checked loss, partial settlement, paid premium,
/// queued pool position and live debt. No random-selection luck is needed for those states.
contract ProtocolLossInvariantTest is ProtocolInvariantTest {
    function setUp() public override {
        super.setUp();
        _exerciseLossScenario();
        _snapshotBootstrap();
    }

    function _metricsPath() internal pure override returns (string memory) {
        return "artifacts/fuzz-and-invariant-tests/loss-metrics.jsonl";
    }
}
