// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseSetup } from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";

// Managers
import { ActorManager } from "@recon/ActorManager.sol";
import { AssetManager } from "@recon/AssetManager.sol";

// Helpers
import { Utils } from "@recon/Utils.sol";
import { ProxyUtils } from "contracts/deploy/utils/ProxyUtils.sol";

// Your deps
import "contracts/feeAuction/FeeAuction.sol";

contract AccessControlMock {
    function checkAccess(bytes4 _selector, address _contract, address _caller) external view returns (bool) {
        return true;
    }
}

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils, ProxyUtils {
    FeeAuction feeAuction;

    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        feeAuction = FeeAuction(_proxy(address(new FeeAuction())));
        feeAuction.initialize(
            address(new AccessControlMock()), // access control is the setup contract
            _newAsset(18), // payment token is the vault's cap token
            _newAsset(18), // payment recipient is the staked cap token
            3 hours, // 3 hour auctions
            1e18 // min price of 1 token
        );
    }

    /// === MODIFIERS === ///
    /// Prank admin and actor

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
        vm.prank(address(_getActor()));
        _;
    }
}
