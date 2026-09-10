// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MockERC20 } from "./MockERC20.sol";

/// @notice A collateral token that calls back into the protocol while a transfer is in flight.
///
/// Governance decides what backs a market, so this is not something an attacker deploys unasked —
/// but plenty of tokens legitimately run code on transfer, and admitting one must not be the same
/// as admitting a reentrancy. The call is made after balances have moved, which is where a real
/// hook sits and the point at which the caller's own bookkeeping may still be half-written.
///
/// Fires once per arming. A hook that re-entered unconditionally would recurse until it ran out of
/// gas and report that rather than whatever the guard did.
contract MockReentrantERC20 is MockERC20 {
    address private target;
    bytes private payload;
    bool private armed;

    /// @notice Whether the callback was reached at all, so a test cannot pass by never firing
    bool public reentered;

    /// @notice Whether the callback itself succeeded. False is the outcome a guard produces
    bool public reentrySucceeded;

    /// @notice What the callback returned, or reverted with. Both are kept so a refusal can be
    /// attributed to the guard rather than to some incidental failure further in, and so a view
    /// can be used to read protocol state from the one moment a hook gets to see it
    bytes public reentryReturn;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) { }

    /// @notice Arrange for the next transfer to call `_target` with `_payload`
    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
        armed = true;
        reentered = false;
        reentrySucceeded = false;
        reentryReturn = "";
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (!armed) return;

        armed = false;
        reentered = true;
        (reentrySucceeded, reentryReturn) = target.call(payload);
    }
}
