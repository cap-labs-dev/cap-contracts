// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Setup } from "./Setup.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

enum OpType {
    GENERIC,
    INVEST,
    DIVEST
}

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        uint256 vaultAssetBalance;
        uint256[] redeemAmountsOut;
        mapping(address => uint256) utilizationIndex;
        mapping(address => uint256) utilizationRatio;
        mapping(address => uint256) totalBorrows;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType _opType) {
        currentOperation = _opType;
        __before();
        _;
        __after();
    }

    function __snapshot(Vars storage vars) internal {
        vars.utilizationIndex[_getAsset()] = capToken.currentUtilizationIndex(_getAsset());
        vars.utilizationRatio[_getAsset()] = capToken.utilization(_getAsset());
        vars.totalBorrows[_getAsset()] = capToken.totalBorrows(_getAsset());
        vars.vaultAssetBalance = MockERC20(_getAsset()).balanceOf(address(capToken));
        try capToken.getRedeemAmount(capToken.balanceOf(_getActor())) returns (
            uint256[] memory amountsOut, uint256[] memory redeemFees
        ) {
            vars.redeemAmountsOut = amountsOut;
        } catch {
            // If the call fails, we can assume the redeem amounts are zero
            vars.redeemAmountsOut = new uint256[](0);
        }
    }

    function __before() internal {
        __snapshot(_before);
    }

    function __after() internal {
        __snapshot(_after);
    }
}
