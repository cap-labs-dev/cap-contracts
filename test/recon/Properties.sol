// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Asserts } from "@chimera/Asserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { IDelegation } from "contracts/interfaces/IDelegation.sol";
import { IFractionalReserve } from "contracts/interfaces/IFractionalReserve.sol";
import { ILender } from "contracts/interfaces/ILender.sol";
import { INetworkMiddleware } from "contracts/interfaces/INetworkMiddleware.sol";
import { IOracle } from "contracts/interfaces/IOracle.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { Lender } from "contracts/lendingPool/Lender.sol";

import { BeforeAfter, OpType } from "./BeforeAfter.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";

abstract contract Properties is BeforeAfter, Asserts {
    /// @dev Property: Sum of deposits is less than or equal to total supply
    function property_sum_of_deposits() public {
        address[] memory actors = _getActors();

        uint256 sumAssets;
        for (uint256 i; i < actors.length; ++i) {
            sumAssets += capToken.balanceOf(actors[i]);
        }
        // include the CUSD minted as fees sent to the insurance fund
        IVault vault = IVault(address(env.usdVault.capToken));
        sumAssets += capToken.balanceOf(vault.insuranceFund());

        uint256 totalSupply = capToken.totalSupply();
        lte(sumAssets, totalSupply, "sum of deposits is > total supply");
    }

    /// @dev Property: Sum of deposits + sum of withdrawals is less than or equal to total supply
    function property_sum_of_withdrawals() public {
        address[] memory actors = _getActors();

        lte(
            ghostAmountIn - ghostAmountOut,
            capToken.totalSupply(),
            "sum of deposits + sum of withdrawals is > total supply"
        );
    }

    /// @dev Property: totalSupplies for a given asset is always <= vault balance + totalBorrows + fractionalReserveBalance
    function property_vault_solvency_assets() public {
        IVault vault = IVault(address(env.usdVault.capToken));
        address[] memory assets = vault.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalSupplied = vault.totalSupplies(assets[i]);
            uint256 totalBorrow = vault.totalBorrows(assets[i]);
            uint256 vaultBalance = MockERC20(assets[i]).balanceOf(address(vault));
            uint256 fractionalReserveBalance =
                MockERC20(assets[i]).balanceOf(IFractionalReserve(address(vault)).fractionalReserveVault(assets[i]));
            lte(
                totalSupplied,
                vaultBalance + totalBorrow + fractionalReserveBalance,
                "totalSupplies > vault balance + totalBorrows"
            );
        }
    }

    /// @dev Property: totalSupplies for a given asset is always >= totalBorrows
    function property_vault_solvency_borrows() public {
        IVault vault = IVault(address(env.usdVault.capToken));
        address[] memory assets = vault.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalSupplied = vault.totalSupplies(assets[i]);
            uint256 totalBorrow = vault.totalBorrows(assets[i]);
            gte(totalSupplied, totalBorrow, "totalSupplies < totalBorrows");
        }
    }

    /// @dev Property: Utilization index only increases
    function property_utilization_index_only_increases() public {
        gte(_after.utilizationIndex[_getAsset()], _before.utilizationIndex[_getAsset()], "utilization index decreased");
    }

    /// @dev Property: Utilization ratio only increases after a borrow
    function property_utilization_ratio() public {
        if (
            currentOperation == OpType.BORROW && _after.utilizationRatio[_getAsset()] != 0
                && _before.utilizationRatio[_getAsset()] != 0
        ) {
            gt(
                _after.utilizationRatio[_getAsset()],
                _before.utilizationRatio[_getAsset()],
                "utilization ratio decreased after a borrow"
            );
        } else {
            gte(
                _before.utilizationRatio[_getAsset()],
                _after.utilizationRatio[_getAsset()],
                "utilization ratio increased without a borrow"
            );
        }
    }

    /// @dev Property: If the vault invests/divests it shouldn't change the redeem amounts out
    function property_vault_balance_does_not_change_redeemAmountsOut() public {
        if (currentOperation == OpType.INVEST || currentOperation == OpType.DIVEST) {
            for (uint256 i; i < _after.redeemAmountsOut.length; ++i) {
                eq(_after.redeemAmountsOut[i], _before.redeemAmountsOut[i], "redeem amounts out changed");
            }
        }
    }

    /// @dev Property: The sum of unrealized interests for all agents always == totalUnrealizedInterest
    // NOTE: can't be implemented because don't have a getter for totalUnrealizedInterest
    function property_sum_of_unrealized_interest() public {
        address[] memory agents = IDelegation(address(delegation)).agents();
        address[] memory assets = IVault(address(env.usdVault.capToken)).assets();

        uint256 sumUnrealizedInterest;
        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j; j < agents.length; ++j) {
                uint256 unrealizedInterest = Lender(address(lender)).unrealizedInterest(agents[j], assets[i]);
                sumUnrealizedInterest += unrealizedInterest;
            }

            uint256 totalUnrealizedInterest = LenderWrapper(address(lender)).getTotalUnrealizedInterest(assets[i]);
            eq(sumUnrealizedInterest, totalUnrealizedInterest, "sum of unrealized interest != totalUnrealizedInterest");
        }
    }

    /// @dev Property: Agent can never have less than minBorrow balance of debt token
    function property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token() public {
        address[] memory agents = IDelegation(address(delegation)).agents();

        for (uint256 i; i < agents.length; ++i) {
            (,, address debtToken,,,, uint256 minBorrow) = ILender(address(lender)).reservesData(_getAsset());
            uint256 agentDebt = MockERC20(debtToken).balanceOf(agents[i]);

            if (agentDebt > 0) {
                gte(agentDebt, minBorrow, "agent has less than minBorrow balance of debt token");
            }
        }
    }

    /// @dev Property: If all users have repaid their debt (have 0 DebtToken balance), reserve.debt == 0
    function property_repaid_debt_equals_zero_debt() public {
        address[] memory agents = IDelegation(address(delegation)).agents();
        address[] memory assets = IVault(address(env.usdVault.capToken)).assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalDebt;
            for (uint256 j; j < agents.length; ++j) {
                totalDebt += ILender(address(lender)).debt(agents[j], assets[i]);
            }

            (,, address debtToken,,,,) = ILender(address(lender)).reservesData(assets[i]);
            uint256 totalDebtTokenSupply = MockERC20(debtToken).totalSupply();

            if (totalDebtTokenSupply == 0) {
                eq(totalDebt, 0, "total debt != 0");
            }
        }
    }

    /// @dev Property: loaned assets value < delegations value (strictly) or the position is liquidatable
    // NOTE: will probably trivially break because the oracle price can be changed by the fuzzer
    function property_borrowed_asset_value() public {
        address[] memory agents = IDelegation(address(delegation)).agents();
        for (uint256 i; i < agents.length; ++i) {
            // Get the agent's debt for the asset
            uint256 agentDebt = ILender(address(lender)).debt(agents[i], _getAsset());
            // Get the asset price from the oracle to calculate value
            (uint256 assetPrice,) = IOracle(address(oracle)).getPrice(_getAsset());
            // Calculate the value in USD (8 decimals)
            uint256 debtValue = agentDebt * assetPrice / (10 ** MockERC20(_getAsset()).decimals());

            (uint256 coverageValue, uint256 coverage) = INetworkMiddleware(mockNetworkMiddleware).coverageByVault(
                address(0), agents[i], env.usdVault.capToken, address(0), uint48(0)
            );

            // check if the value of the loaned amount is < the coverage value
            if (debtValue < coverageValue) {
                // if true, the position must be liquidatable
                (,,,,, uint256 health) = ILender(address(lender)).agent(agents[i]);
                // check if the position is liquidatable
                lt(health, 1e27, "position is not liquidatable");
            }
        }
    }

    /// @dev Property: LTV is always <= 1e27
    function property_ltv() public {
        address[] memory agents = IDelegation(address(delegation)).agents();
        for (uint256 i; i < agents.length; ++i) {
            (,,,, uint256 ltv,) = ILender(address(lender)).agent(agents[i]);
            lte(ltv, 1e27, "ltv > 1e27");
        }
    }

    /// @dev Property: health should not change when interest is realized
    function property_health_not_changed_with_realizeInterest() public {
        if (currentOperation == OpType.REALIZE_INTEREST) {
            eq(_after.agentHealth[_getActor()], _before.agentHealth[_getActor()], "health changed with realizeInterest");
        }
    }

    /// @dev Property: agent'stotal debt should not change when interest is realized
    function property_total_debt_not_changed_with_realizeInterest() public {
        if (currentOperation == OpType.REALIZE_INTEREST) {
            eq(
                _after.agentTotalDebt[_getActor()],
                _before.agentTotalDebt[_getActor()],
                "total debt changed with realizeInterest"
            );
        }
    }

    /// @dev Property: The vault debt should increase by the same amount that the underlying asset in the vault decreases when interest is realized
    function property_vault_debt_increase() public {
        if (currentOperation == OpType.REALIZE_INTEREST) {
            uint256 debtIncrease = _after.totalVaultDebt[_getAsset()] - _before.totalVaultDebt[_getAsset()];
            uint256 assetDecrease = _before.vaultAssetBalance - _after.vaultAssetBalance;
            eq(debtIncrease, assetDecrease, "vault debt increase != asset decrease");
        }
    }

    /// @dev Property: The debt token balance of the agent should increase by the same amount that the total borrows of the asset increases when interest is realized
    function property_debt_increase_after_realizing_interest() public {
        if (currentOperation == OpType.REALIZE_INTEREST) {
            uint256 debtIncrease =
                _after.debtTokenBalance[_getAsset()][_getActor()] - _before.debtTokenBalance[_getAsset()][_getActor()];
            uint256 borrowsIncrease = _after.totalBorrows[_getAsset()] - _before.totalBorrows[_getAsset()];
            eq(debtIncrease, borrowsIncrease, "debt increase != borrows increase");
        }
    }
}
