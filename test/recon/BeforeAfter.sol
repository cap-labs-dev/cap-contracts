// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Setup } from "./Setup.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
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

    function __before() internal {
        IVault vault = IVault(address(env.usdVault.capToken));
        _before.utilizationIndex[_getAsset()] = vault.currentUtilizationIndex(_getAsset());
        _before.utilizationRatio[_getAsset()] = vault.utilization(_getAsset());
        _before.totalBorrows[_getAsset()] = vault.totalBorrows(_getAsset());
        _before.vaultAssetBalance = MockERC20(_getAsset()).balanceOf(address(vault));
        (_before.redeemAmountsOut,) = capToken.getRedeemAmount(capToken.balanceOf(_getActor()));
    }

    function __after() internal {
        IVault vault = IVault(address(env.usdVault.capToken));
        _after.utilizationIndex[_getAsset()] = vault.currentUtilizationIndex(_getAsset());
        _after.utilizationRatio[_getAsset()] = vault.utilization(_getAsset());
        _after.totalBorrows[_getAsset()] = vault.totalBorrows(_getAsset());
        _after.vaultAssetBalance = MockERC20(_getAsset()).balanceOf(address(vault));
        (_after.redeemAmountsOut,) = capToken.getRedeemAmount(capToken.balanceOf(_getActor()));
    }
}
