// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MockERC4626 } from "./MockERC4626.sol";

/// @dev ERC4626 that can fire a one-shot call into another contract during withdraw/redeem.
/// Used to exercise CapToken reentrancy guards on paths that divest from a fractional reserve.
contract MockReentrantERC4626 is MockERC4626 {
    address public attackTarget;
    bytes public attackData;
    bool public attackEnabled;

    constructor(address _asset, uint256 _interestRate, string memory _name, string memory _symbol)
        MockERC4626(_asset, _interestRate, _name, _symbol)
    { }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
        attackEnabled = true;
    }

    function clearAttack() external {
        attackEnabled = false;
        attackData = "";
        attackTarget = address(0);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _maybeAttack();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _maybeAttack();
        return super.redeem(shares, receiver, owner);
    }

    function _maybeAttack() private {
        if (!attackEnabled) return;
        attackEnabled = false;
        address target = attackTarget;
        bytes memory data = attackData;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
