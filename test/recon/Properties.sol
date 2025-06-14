// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Asserts } from "@chimera/Asserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { BeforeAfter, OpType } from "./BeforeAfter.sol";
import { LenderWrapper } from "test/recon/helpers/LenderWrapper.sol";
import { MockERC4626Tester } from "test/recon/mocks/MockERC4626Tester.sol";

abstract contract Properties is BeforeAfter, Asserts {
    /// @dev Property: Sum of deposits is less than or equal to total supply
    function property_sum_of_deposits() public {
        address[] memory actors = _getActors();

        uint256 sumAssets;
        for (uint256 i; i < actors.length; ++i) {
            sumAssets += capToken.balanceOf(actors[i]);
        }
        // include the CUSD minted as fees sent to the insurance fund
        sumAssets += capToken.balanceOf(capToken.insuranceFund());

        uint256 totalSupply = capToken.totalSupply();
        lte(sumAssets, totalSupply, "sum of deposits is > total supply");
    }

    /// @dev Property: Sum of deposits + sum of withdrawals is less than or equal to total supply
    function property_sum_of_withdrawals() public {
        lte(
            ghostAmountIn - ghostAmountOut,
            capToken.totalSupply(),
            "sum of deposits + sum of withdrawals is > total supply"
        );
    }

    /// @dev Property: totalSupplies for a given asset is always <= vault balance + totalBorrows + fractionalReserveBalance
    function property_vault_solvency_assets() public {
        address[] memory assets = capToken.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalSupplied = capToken.totalSupplies(assets[i]);
            uint256 totalBorrow = capToken.totalBorrows(assets[i]);
            uint256 vaultBalance = MockERC20(assets[i]).balanceOf(address(capToken));
            uint256 fractionalReserveBalance =
                MockERC20(assets[i]).balanceOf(capToken.fractionalReserveVault(assets[i]));
            uint256 fractionalReserveLosses = _getFractionalReserveLosses(assets[i]);

            lte(
                totalSupplied,
                vaultBalance + totalBorrow + fractionalReserveBalance + fractionalReserveLosses,
                "totalSupplies > vault balance + totalBorrows"
            );
        }
    }

    /// @dev Property: totalSupplies for a given asset is always >= totalBorrows
    function property_vault_solvency_borrows() public {
        address[] memory assets = capToken.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalSupplied = capToken.totalSupplies(assets[i]);
            uint256 totalBorrow = capToken.totalBorrows(assets[i]);
            gte(totalSupplied, totalBorrow, "totalSupplies < totalBorrows");
        }
    }

    /// @dev Property: Utilization index only increases
    function property_utilization_index_only_increases() public {
        gte(_after.utilizationIndex[_getAsset()], _before.utilizationIndex[_getAsset()], "utilization index decreased");
    }

    /// @dev Property: Utilization ratio only increases after a borrow or realizing interest
    // NOTE: removed because it makes incorrect assumptions about the utilization ratio
    // function property_utilization_ratio() public {
    //     // precondition: if the utilization ratio is 0 before and after, the borrowed amount was 0
    //     if (
    //         (currentOperation == OpType.BORROW || currentOperation == OpType.REALIZE_INTEREST)
    //             && _before.utilizationRatio[_getAsset()] == 0 && _after.utilizationRatio[_getAsset()] == 0
    //     ) {
    //         return;
    //     }

    //     if (currentOperation == OpType.BORROW || currentOperation == OpType.REALIZE_INTEREST) {
    //         gte(
    //             _after.utilizationRatio[_getAsset()],
    //             _before.utilizationRatio[_getAsset()],
    //             "utilization ratio decreased after a borrow"
    //         );
    //     } else {
    //         eq(
    //             _before.utilizationRatio[_getAsset()],
    //             _after.utilizationRatio[_getAsset()],
    //             "utilization ratio increased without a borrow"
    //         );
    //     }
    // }

    /// @dev Property: If the vault invests/divests it shouldn't change the redeem amounts out
    function property_vault_balance_does_not_change_redeemAmountsOut() public {
        if (currentOperation == OpType.INVEST || currentOperation == OpType.DIVEST) {
            for (uint256 i; i < _after.redeemAmountsOut.length; ++i) {
                eq(_after.redeemAmountsOut[i], _before.redeemAmountsOut[i], "redeem amounts out changed");
            }
        }
    }

    /// @dev Property: The sum of unrealized interests for all agents always == totalUnrealizedInterest
    function property_sum_of_unrealized_interest() public {
        address[] memory agents = delegation.agents();
        address[] memory assets = capToken.assets();

        uint256 sumUnrealizedInterest;
        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j; j < agents.length; ++j) {
                uint256 unrealizedInterest = lender.unrealizedInterest(agents[j], assets[i]);
                sumUnrealizedInterest += unrealizedInterest;
            }

            uint256 totalUnrealizedInterest = LenderWrapper(address(lender)).getTotalUnrealizedInterest(assets[i]);
            eq(sumUnrealizedInterest, totalUnrealizedInterest, "sum of unrealized interest != totalUnrealizedInterest");
        }
    }

    /// @dev Property: Agent can never have less than minBorrow balance of debt token
    function property_agent_cannot_have_less_than_minBorrow_balance_of_debt_token() public {
        address[] memory agents = delegation.agents();

        for (uint256 i; i < agents.length; ++i) {
            (,, address _debtToken,,,, uint256 minBorrow) = lender.reservesData(_getAsset());
            uint256 agentDebt = MockERC20(_debtToken).balanceOf(agents[i]);

            if (agentDebt > 0) {
                gte(agentDebt, minBorrow, "agent has less than minBorrow balance of debt token");
            }
        }
    }

    /// @dev Property: If all users have repaid their debt (have 0 DebtToken balance), reserve.debt == 0
    function property_repaid_debt_equals_zero_debt() public {
        address[] memory agents = delegation.agents();
        address[] memory assets = capToken.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalDebt;
            for (uint256 j; j < agents.length; ++j) {
                totalDebt += lender.debt(agents[j], assets[i]);
            }

            (,, address _debtToken,,,,) = lender.reservesData(assets[i]);
            uint256 totalDebtTokenSupply = MockERC20(_debtToken).totalSupply();

            if (totalDebtTokenSupply == 0) {
                eq(totalDebt, 0, "total debt != 0");
            }
        }
    }

    /// @dev Property: loaned assets value < delegations value (strictly) or the position is liquidatable
    // NOTE: will probably trivially break because the oracle price can be changed by the fuzzer
    function property_borrowed_asset_value() public {
        address[] memory agents = delegation.agents();
        for (uint256 i; i < agents.length; ++i) {
            uint256 agentDebt = lender.debt(agents[i], _getAsset());
            (uint256 assetPrice,) = oracle.getPrice(_getAsset());
            uint256 debtValue = agentDebt * assetPrice / (10 ** MockERC20(_getAsset()).decimals());

            (uint256 coverageValue,) =
                mockNetworkMiddleware.coverageByVault(address(0), agents[i], mockEth, address(0), uint48(0));

            if (debtValue > coverageValue) {
                (,,,,, uint256 health) = lender.agent(agents[i]);
                lt(health, 1e27, "position is not liquidatable");
            }
        }
    }

    /// @dev Property: LTV is always <= 1e27
    function property_ltv() public {
        address[] memory agents = delegation.agents();
        for (uint256 i; i < agents.length; ++i) {
            (,,,, uint256 ltv,) = lender.agent(agents[i]);
            lte(ltv, 1e27, "ltv > 1e27");
        }
    }

    /// @dev Property: system must be overcollateralized after all liquidations
    // TODO: check if the minimum shouldn't be > 1e27
    function property_total_system_collateralization() public {
        address[] memory agents = delegation.agents();
        uint256 totalDelegation;
        uint256 totalDebt;

        // precondition: all agents that are liquidatable have been liquidated
        for (uint256 i = 0; i < agents.length; i++) {
            (,,,,, uint256 health) = lender.agent(agents[i]);
            if (health < 1e27) {
                return;
            }
        }

        for (uint256 i = 0; i < agents.length; i++) {
            (uint256 agentDelegation,, uint256 agentDebt,,,) = lender.agent(agents[i]);
            totalDelegation += agentDelegation;
            totalDebt += agentDebt;
        }

        // get the total system collateralization ratio
        uint256 ratio = totalDebt == 0 ? type(uint256).max : (totalDelegation * 1e27) / totalDebt;
        gte(ratio, 1e27, "total system collateralization ratio < 1e27");
    }

    /// @dev Property: Delegated value must be greater than borrowed value, if not the agent should be liquidatable
    function property_delegated_value_greater_than_borrowed_value() public {
        address[] memory agents = delegation.agents();
        for (uint256 i; i < agents.length; ++i) {
            (uint256 agentDelegation,, uint256 agentDebt,,, uint256 health) = lender.agent(agents[i]);
            if (agentDelegation < agentDebt) {
                t(health < 1e27, "delegated value < borrowed value and agent is not liquidatable");
            }
        }
    }

    function property_burn_amount_no_fee() public {
        if (currentOperation == OpType.BURN && _after.capTotalSupply != _before.capTotalSupply) {
            gt(_after.insuranceFundBalance, _before.insuranceFundBalance, "0 fees on burn");
        }
    }

    /// @dev Property: cUSD (capToken) must be backed 1:1 by stable underlying assets
    function property_cap_token_backed_1_to_1() public {
        address[] memory assets = capToken.assets();
        uint256 totalBackingValue = 0;
        bool hasUnrealisticPrice = false;
        (uint256 capPrice,) = oracle.getPrice(address(capToken));

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            (uint256 assetPrice,) = oracle.getPrice(asset);

            // Sanity check: For stablecoins, price should be between $0.50 and $2.00
            // In Chainlink format (8 decimals): 0.85e8 to 1.05e8
            if (assetPrice < 0.85e8 || assetPrice > 1.05e8) {
                hasUnrealisticPrice = true;
                continue; // Skip this asset if price is unrealistic
            }

            uint256 vaultBalance = MockERC20(asset).balanceOf(address(capToken));
            uint256 totalBorrows = capToken.totalBorrows(asset);
            uint256 fractionalReserveBalance = MockERC20(asset).balanceOf(capToken.fractionalReserveVault(asset));

            uint256 totalAssetAmount =
                vaultBalance + totalBorrows + fractionalReserveBalance + _getFractionalReserveLosses(asset);

            uint256 assetDecimals = MockERC20(asset).decimals();
            uint256 assetValue = totalAssetAmount * assetPrice * 1e18 / (10 ** assetDecimals * 1e8);

            totalBackingValue += assetValue;
        }

        // Skip property check if any asset has unrealistic pricing (likely due to fuzzer manipulation)
        if (hasUnrealisticPrice) {
            return;
        }

        uint256 capTokenTotalSupply = capToken.totalSupply();

        if (capTokenTotalSupply == 0) {
            return;
        }

        gte(totalBackingValue, capTokenTotalSupply * capPrice / 1e8, "capToken not backed 1:1 by underlying assets");
    }

    /// @dev Property: DebtToken balance ≥ total vault debt at all times
    function property_debt_token_balance_gte_total_vault_debt() public {
        address[] memory assets = capToken.assets();
        address[] memory agents = delegation.agents();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            (,, address _debtToken,,,,) = lender.reservesData(asset);

            if (_debtToken == address(0)) {
                continue;
            }

            uint256 totalDebtTokenSupply = MockERC20(_debtToken).totalSupply();

            uint256 totalVaultDebt = 0;
            for (uint256 j = 0; j < agents.length; j++) {
                totalVaultDebt += lender.debt(agents[j], asset);
            }

            gte(totalDebtTokenSupply, totalVaultDebt, "DebtToken balance < total vault debt");
        }
    }

    /// @dev Property: Total cUSD borrowed < total supply (utilization < 1e27)
    function property_total_borrowed_less_than_total_supply() public {
        address[] memory assets = capToken.assets();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            uint256 totalSupplied = capToken.totalSupplies(asset);
            uint256 totalBorrowed = capToken.totalBorrows(asset);

            // Skip if no supplies (division by zero in utilization calculation)
            if (totalSupplied == 0) {
                // If no supplies, there should be no borrows either
                eq(totalBorrowed, 0, "borrows exist without supplies");
                continue;
            }

            lte(totalBorrowed, totalSupplied, "total borrowed > total supply");
            uint256 utilizationRatio = capToken.utilization(asset);
            lte(utilizationRatio, 1e27, "utilization > 100%");

            uint256 expectedUtilization = totalBorrowed * 1e27 / totalSupplied;

            uint256 diff = utilizationRatio > expectedUtilization
                ? utilizationRatio - expectedUtilization
                : expectedUtilization - utilizationRatio;
            lte(diff * 10000, 1e27, "utilization calculation inconsistent");
        }
    }

    /// @dev Property: Staked cap token value must increase or stay the same over time
    function property_staked_cap_value_non_decreasing() public {
        uint256 valuePerShareBefore = _before.stakedCapValuePerShare;
        uint256 valuePerShareAfter = _after.stakedCapValuePerShare;

        // Skip if no meaningful value tracked (initial state or failed calls)
        if (valuePerShareBefore == 0 || valuePerShareAfter == 0) {
            return;
        }

        // Skip if values are exactly the same (no change)
        if (valuePerShareBefore == valuePerShareAfter) {
            return;
        }

        gte(valuePerShareAfter, valuePerShareBefore, "staked cap token value per share decreased");

        if (valuePerShareAfter < valuePerShareBefore) {
            uint256 decrease = valuePerShareBefore - valuePerShareAfter;
            uint256 decreasePercentage = decrease * 10000 / valuePerShareBefore; // basis points
            lte(decreasePercentage, 1, "staked cap value decreased by more than 0.01%");
        }
    }

    /// === Optimization Properties === ///

    function optimize_burnable_amount_no_fee() public returns (int256) {
        return maxAmountOut;
    }

    /// === Helpers === ///
    function _getFractionalReserveLosses(address _asset) internal view returns (uint256) {
        address fractionalReserveVault = capToken.fractionalReserveVault(_asset);

        if (fractionalReserveVault == address(0)) {
            return 0;
        } else {
            return MockERC4626Tester(fractionalReserveVault).totalLosses();
        }
    }
}
