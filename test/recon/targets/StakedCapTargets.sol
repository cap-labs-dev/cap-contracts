// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/token/StakedCap.sol";

abstract contract StakedCapTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function stakedCap_approve(address spender, uint256 value) public asActor {
        stakedCap.approve(spender, value);
    }

    function stakedCap_deposit(uint256 assets, address receiver) public asActor {
        stakedCap.deposit(assets, receiver);
    }

    function stakedCap_mint(uint256 shares, address receiver) public asActor {
        stakedCap.mint(shares, receiver);
    }

    function stakedCap_notify() public asActor {
        stakedCap.notify();
    }

    function stakedCap_permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public asActor {
        stakedCap.permit(owner, spender, value, deadline, v, r, s);
    }

    function stakedCap_redeem(uint256 shares, address receiver, address owner) public asActor {
        stakedCap.redeem(shares, receiver, owner);
    }

    function stakedCap_transfer(address to, uint256 value) public asActor {
        stakedCap.transfer(to, value);
    }

    function stakedCap_transferFrom(address from, address to, uint256 value) public asActor {
        stakedCap.transferFrom(from, to, value);
    }

    function stakedCap_withdraw(uint256 assets, address receiver, address owner) public asActor {
        stakedCap.withdraw(assets, receiver, owner);
    }
}
