// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/feeAuction/FeeAuction.sol";

abstract contract FeeAuctionTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function feeAuction_buy_clamped(uint256 _maxPrice, uint256 _minAmount) public {
        address[] memory _assets = new address[](1);
        _assets[0] = _getAsset();
        uint256[] memory _minAmounts = new uint256[](1);
        _minAmounts[0] = _minAmount;
        feeAuction_buy(_maxPrice, _assets, _minAmounts, _getActor(), block.timestamp + 1000);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function feeAuction_buy(
        uint256 _maxPrice,
        address[] memory _assets,
        uint256[] memory _minAmounts,
        address _receiver,
        uint256 _deadline
    ) public asActor {
        feeAuction.buy(_maxPrice, _assets, _minAmounts, _receiver, _deadline);
    }

    function feeAuction_setDuration(uint256 _duration) public asActor {
        feeAuction.setDuration(_duration);
    }

    function feeAuction_setMinStartPrice(uint256 _minStartPrice) public asActor {
        feeAuction.setMinStartPrice(_minStartPrice);
    }

    function feeAuction_setStartPrice(uint256 _startPrice) public asActor {
        feeAuction.setStartPrice(_startPrice);
    }
}
