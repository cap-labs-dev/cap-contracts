// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Asserts } from "@chimera/Asserts.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { IVault } from "contracts/interfaces/IVault.sol";

import { BeforeAfter } from "./BeforeAfter.sol";

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

    /// @dev Property: totalSupplies for a given asset is always <= vault balance + totalBorrows
    function property_vault_solvency_assets() public {
        IVault vault = IVault(address(env.usdVault.capToken));
        address[] memory assets = vault.assets();

        for (uint256 i; i < assets.length; ++i) {
            uint256 totalSupplied = vault.totalSupplies(assets[i]);
            uint256 totalBorrow = vault.totalBorrows(assets[i]);
            uint256 vaultBalance = MockERC20(assets[i]).balanceOf(address(vault));
            lte(totalSupplied, vaultBalance + totalBorrow, "totalSupplies > vault balance + totalBorrows");
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
}
