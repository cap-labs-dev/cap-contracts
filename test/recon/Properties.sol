// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Asserts } from "@chimera/Asserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { IFractionalReserve } from "contracts/interfaces/IFractionalReserve.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

import { BeforeAfter, OpType } from "./BeforeAfter.sol";

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

    /// @dev Property: Utilization ratio only decreases after a borrow
    function property_utilization_ratio() public {
        // precondition: total borrows increases
        if (_after.totalBorrows[_getAsset()] > _before.totalBorrows[_getAsset()]) {
            lt(
                _after.utilizationRatio[_getAsset()],
                _before.utilizationRatio[_getAsset()],
                "utilization ratio increased after a borrow"
            );
        } else {
            // precondition: total borrows does not increase
            gte(
                _after.utilizationRatio[_getAsset()],
                _before.utilizationRatio[_getAsset()],
                "utilization ratio decreased without a borrow"
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
}
