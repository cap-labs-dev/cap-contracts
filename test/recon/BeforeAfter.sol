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

        vars.redeemAmountsOut = _getRedeemAmounts(_getActor());
        (,, vars.agentTotalDebt[_getActor()],,, vars.agentHealth[_getActor()]) = _getAgentParams(_getActor());
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

        // Store user debt as the debt token balance
        vars.debtTokenBalance[_getAsset()][_getActor()] = MockERC20(debtToken).balanceOf(_getActor());
    }

    function _getAgentParams(address _agent)
        internal
        view
        returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        )
    {
        try lender.agent(_agent) returns (
            uint256 _totalDelegation,
            uint256 _totalSlashableCollateral,
            uint256 _totalDebt,
            uint256 _ltv,
            uint256 _liquidationThreshold,
            uint256 _health
        ) {
            totalDelegation = _totalDelegation;
            totalSlashableCollateral = _totalSlashableCollateral;
            totalDebt = _totalDebt;
            ltv = _ltv;
            liquidationThreshold = _liquidationThreshold;
            health = _health;
        } catch {
            // If the call fails, we can assume the health is 0
            totalDelegation = 0;
            totalSlashableCollateral = 0;
            totalDebt = 0;
            ltv = 0;
            liquidationThreshold = 0;
            health = 0;
        }
    }

    function _getRedeemAmounts(address _agent) internal view returns (uint256[] memory amountsOut) {
        try capToken.getRedeemAmount(capToken.balanceOf(_agent)) returns (
            uint256[] memory _amountsOut, uint256[] memory _redeemFees
        ) {
            amountsOut = _amountsOut;
        } catch {
            // If the call fails, we can assume the redeem amounts are zero
            amountsOut = new uint256[](0);
        }
    }
}
