// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/lendingPool/Lender.sol";

abstract contract LenderTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function lender_addAsset(ILender.AddAssetParams memory _params) public asActor {
        lender.addAsset(_params);
    }

    function lender_borrow(address _asset, uint256 _amount, address _receiver) public asActor {
        lender.borrow(_asset, _amount, _receiver);
    }

    function lender_cancelLiquidation(address _agent) public asActor {
        lender.cancelLiquidation(_agent);
    }

    function lender_initialize(
        address _accessControl,
        address _delegation,
        address _oracle,
        uint256 _targetHealth,
        uint256 _grace,
        uint256 _expiry,
        uint256 _bonusCap,
        uint256 _emergencyLiquidationThreshold
    ) public asActor {
        lender.initialize(
            _accessControl,
            _delegation,
            _oracle,
            _targetHealth,
            _grace,
            _expiry,
            _bonusCap,
            _emergencyLiquidationThreshold
        );
    }

    function lender_initiateLiquidation(address _agent) public asActor {
        lender.initiateLiquidation(_agent);
    }

    function lender_liquidate(address _agent, address _asset, uint256 _amount) public asActor {
        lender.liquidate(_agent, _asset, _amount);
    }

    function lender_pauseAsset(address _asset, bool _pause) public asActor {
        lender.pauseAsset(_asset, _pause);
    }

    function lender_realizeInterest(address _asset) public asActor {
        lender.realizeInterest(_asset);
    }

    function lender_realizeRestakerInterest(address _agent, address _asset) public asActor {
        lender.realizeRestakerInterest(_agent, _asset);
    }

    function lender_removeAsset(address _asset) public asActor {
        lender.removeAsset(_asset);
    }

    function lender_repay(address _asset, uint256 _amount, address _agent) public asActor {
        lender.repay(_asset, _amount, _agent);
    }

    function lender_setMinBorrow(address _asset, uint256 _minBorrow) public asActor {
        lender.setMinBorrow(_asset, _minBorrow);
    }

    function lender_upgradeToAndCall(address newImplementation, bytes memory data) public payable asActor {
        lender.upgradeToAndCall{ value: msg.value }(newImplementation, data);
    }
}
