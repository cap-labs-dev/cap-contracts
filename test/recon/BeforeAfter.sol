// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { MockERC20 } from "@recon/MockERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { ILender } from "contracts/interfaces/ILender.sol";

import { Setup } from "./Setup.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

enum OpType {
    GENERIC,
    INVEST,
    DIVEST,
    BORROW,
    REALIZE_INTEREST
}

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        uint256 vaultAssetBalance;
        uint256[] redeemAmountsOut;
        mapping(address => mapping(address => uint256)) debtTokenBalance;
        mapping(address => uint256) vaultDebt;
        mapping(address => uint256) agentHealth;
        mapping(address => uint256) agentTotalDebt;
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
        _updateVaultDebt(vars);

        vars.utilizationIndex[_getAsset()] = capToken.currentUtilizationIndex(_getAsset());
        vars.utilizationRatio[_getAsset()] = capToken.utilization(_getAsset());
        vars.totalBorrows[_getAsset()] = capToken.totalBorrows(_getAsset());
        vars.vaultAssetBalance = MockERC20(_getAsset()).balanceOf(address(capToken));
        vars.vaultDebt[_getAsset()] = LenderWrapper(address(lender)).getVaultDebt(_getAsset());

        try capToken.getRedeemAmount(capToken.balanceOf(_getActor())) returns (
            uint256[] memory amountsOut, uint256[] memory redeemFees
        ) {
            vars.redeemAmountsOut = amountsOut;
        } catch {
            // If the call fails, we can assume the redeem amounts are zero
            vars.redeemAmountsOut = new uint256[](0);
        }
        try lender.agent(_getActor()) returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        ) {
            vars.agentHealth[_getActor()] = health;
            vars.agentTotalDebt[_getActor()] = totalDebt;
        } catch {
            // If the call fails, we can assume the health is 0
            vars.agentHealth[_getActor()] = 0;
            vars.agentTotalDebt[_getActor()] = 0;
        }
    }

    function __before() internal {
        __snapshot(_before);
    }

    function __after() internal {
        __snapshot(_after);
    }

    function _updateVaultDebt(Vars storage vars) internal {
        // Get the debt token address for the current asset
        (,, address debtToken,,,,) = lender.reservesData(_getAsset());

        // Store total debt as the debt token's total supply
        vars.debtTokenBalance[_getAsset()][_getActor()] = MockERC20(debtToken).balanceOf(_getActor());
    }
}
