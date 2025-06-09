// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";
import { console2 } from "forge-std/console2.sol";

// Helpers
import { MockERC20 } from "@recon/MockERC20.sol";
import { Panic } from "@recon/Panic.sol";

import { IMinter } from "contracts/interfaces/IMinter.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import "contracts/token/CapToken.sol";
import { VaultLogic } from "contracts/vault/libraries/VaultLogic.sol";

import { BeforeAfter, OpType } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";

abstract contract CapTokenTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function capToken_mint_clamped(uint256 _amountIn) public {
        capToken_mint(_getAsset(), _amountIn, 0, _getActor(), block.timestamp + 1 days);
    }

    function capToken_burn_clamped(uint256 _amountIn) public {
        capToken_burn(_getAsset(), _amountIn, 0, _getActor(), block.timestamp + 1 days);
    }

    function capToken_redeem_clamped(uint256 _amountIn) public {
        uint256[] memory _minAmountsOut = new uint256[](3);
        _minAmountsOut[0] = 0; // Set minimum amount out to 0 for clamping
        _minAmountsOut[1] = 0; // Set minimum amount out to 0 for clamping
        _minAmountsOut[2] = 0; // Set minimum amount out to 0 for clamping
        capToken_redeem(_amountIn, _minAmountsOut, _getActor(), block.timestamp + 1 days);
    }

    function capToken_setFractionalReserveVault_clamped() public {
        capToken_setFractionalReserveVault(_getAsset(), _getVault());
    }

    function capToken_setReserve_clamped(uint256 _reserve) public {
        capToken_setReserve(_getAsset(), _reserve);
    }

    function capToken_investAll_clamped() public {
        capToken_investAll(_getAsset());
    }

    function capToken_divestAll_clamped() public {
        capToken_divestAll(_getAsset());
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function capToken_addAsset() public updateGhosts asActor {
        capToken.addAsset(_getAsset());
    }

    function capToken_approve(address spender, uint256 value) public asActor {
        bool value0;
        try capToken.approve(spender, value) returns (bool tempValue0) {
            value0 = tempValue0;
        } catch (bytes memory err) {
            bool expectedError = checkError(err, "ERC20InvalidSpender(address)");
            if (!expectedError) {
                t(false, "capToken_approve");
            }
        }
    }

    // @audit info: This function can only be called by the Lender contract to borrow assets.
    // function capToken_borrow(address _asset, uint256 _amount, address _receiver) public asActor {
    //     capToken.borrow(_asset, _amount, _receiver);
    //     t(false, "capToken_borrow");
    // }

    /// @dev Property: User can always burn cap token if they have sufficient balance of cap token
    /// @dev Property: User always receives at least the minimum amount out
    /// @dev Property: User always receives at most the expected amount out
    /// @dev Property: Total cap supply decreases by no more than the amount out
    /// @dev Property: Fees are always nonzero when burning
    /// @dev Property: Fees are always <= the amount out
    function capToken_burn(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) public updateGhosts {
        IVault vault = IVault(address(env.usdVault.capToken));
        uint256 capTokenBalanceBefore = capToken.balanceOf(_getActor());
        uint256 insuranceFundBalanceBefore = MockERC20(_asset).balanceOf(vault.insuranceFund());
        uint256 totalCapSupplyBefore = capToken.totalSupply();
        (uint256 expectedAmountOut,) = capToken.getBurnAmount(_asset, _amountIn);

        vm.prank(_getActor());
        try capToken.burn(_asset, _amountIn, _minAmountOut, _receiver, _deadline) {
            // update variables for inlined properties
            uint256 capTokenBalanceAfter = capToken.balanceOf(_getActor());
            uint256 insuranceFundBalanceAfter = MockERC20(_asset).balanceOf(vault.insuranceFund());
            uint256 totalCapSupplyAfter = capToken.totalSupply();

            // update ghosts
            ghostAmountOut += _amountIn;

            // check inlined properties
            gte(
                capTokenBalanceBefore - capTokenBalanceAfter,
                _minAmountOut,
                "user received less than minimum amount out"
            );
            gte(
                totalCapSupplyBefore - totalCapSupplyAfter,
                capTokenBalanceBefore - capTokenBalanceAfter,
                "total cap supply decreased by less than the amount out"
            );
            lte(
                insuranceFundBalanceAfter - insuranceFundBalanceBefore,
                capTokenBalanceBefore - capTokenBalanceAfter,
                "fees are greater than the amount out"
            );
            if (!IMinter(address(vault)).whitelisted(_getActor())) {
                gt(insuranceFundBalanceAfter - insuranceFundBalanceBefore, 0, "0 fees when burning");

                lte(
                    capTokenBalanceAfter,
                    capTokenBalanceBefore - expectedAmountOut,
                    "user received more than expected amount out"
                );
            }
        } catch (bytes memory err) {
            bool expectedError = checkError(err, "PastDeadline()")
                || checkError(err, "Slippage(address,uint256,uint256)") || checkError(err, "InvalidAmount()")
                || checkError(err, "AssetNotSupported(address)")
                || checkError(err, "InsufficientReserves(address,uint256,uint256)");
            bool isPaused = capToken.paused();
            if (!expectedError && _amountIn > 0 && !isPaused) {
                lt(capTokenBalanceBefore, _amountIn, "user cannot burn with sufficient cap token balance");
            }
        }
    }

    function capToken_divestAll(address _asset) public updateGhostsWithType(OpType.DIVEST) asActor {
        capToken.divestAll(_asset);
    }

    function capToken_investAll(address _asset) public updateGhostsWithType(OpType.INVEST) asActor {
        capToken.investAll(_asset);
    }

    /// @dev Property: User can always mint cap token if they have sufficient balance of depositing asset
    /// @dev Property: User always receives at least the minimum amount out
    /// @dev Property: User always receives at most the expected amount out
    /// @dev Property: Fees are always nonzero when minting
    /// @dev Property: Fees are always <= the amount out
    function capToken_mint(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) public updateGhosts {
        IVault vault = IVault(address(env.usdVault.capToken));
        uint256 assetBalance = MockERC20(_asset).balanceOf(_getActor());
        uint256 capTokenBalanceBefore = capToken.balanceOf(_receiver);
        uint256 insuranceFundBalanceBefore = capToken.balanceOf(vault.insuranceFund());
        (uint256 expectedAmountOut,) = capToken.getMintAmount(_asset, _amountIn);
        bool isAssetPaused = capToken.paused(_asset);

        vm.prank(_getActor());
        try capToken.mint(_asset, _amountIn, _minAmountOut, _receiver, _deadline) returns (uint256 amountOut) {
            uint256 capTokenBalanceAfter = capToken.balanceOf(_receiver);
            uint256 insuranceFundBalanceAfter = capToken.balanceOf(vault.insuranceFund());

            // update ghosts
            ghostAmountIn += amountOut;

            gte(
                capTokenBalanceAfter - capTokenBalanceBefore,
                _minAmountOut,
                "user received less than minimum amount out"
            );
            lte(
                insuranceFundBalanceAfter - insuranceFundBalanceBefore,
                capTokenBalanceAfter - capTokenBalanceBefore,
                "fees are greater than the amount out"
            );
            if (!IMinter(address(vault)).whitelisted(_getActor())) {
                gt(insuranceFundBalanceAfter - insuranceFundBalanceBefore, 0, "0 fees when minting");

                lte(
                    capTokenBalanceAfter,
                    capTokenBalanceBefore + expectedAmountOut,
                    "user received more than expected amount out"
                );
            }
            t(!isAssetPaused, "asset can be minted when it is paused");
        } catch (bytes memory err) {
            bool expectedError = checkError(err, "PastDeadline()")
                || checkError(err, "Slippage(address,uint256,uint256)") || checkError(err, "InvalidAmount()")
                || checkError(err, "AssetNotSupported(address)") || checkError(err, "ERC20InvalidReceiver(address)");
            bool isProtocolPaused = capToken.paused();

            if (!expectedError && _amountIn > 0 && !isProtocolPaused && !isAssetPaused) {
                lt(assetBalance, _amountIn, "user cannot mint with sufficient asset balance");
            }
        }
    }

    function capToken_pauseAsset(address _asset) public updateGhosts asActor {
        capToken.pauseAsset(_asset);
    }

    function capToken_pauseProtocol() public updateGhosts asActor {
        capToken.pauseProtocol();
    }

    // function capToken_permit(
    //     address owner,
    //     address spender,
    //     uint256 value,
    //     uint256 deadline,
    //     uint8 v,
    //     bytes32 r,
    //     bytes32 s
    // ) public asActor {
    //     capToken.permit(owner, spender, value, deadline, v, r, s);
    // }

    function capToken_realizeInterest(address _asset) public updateGhosts asActor {
        capToken.realizeInterest(_asset);
    }

    /// @dev Property: User can always redeem cap token if they have sufficient balance of cap token
    /// @dev Property: User always receives at least the minimum amount out
    /// @dev Property: User always receives at most the expected amount out
    /// @dev Property: Total cap supply decreases by no more than the amount out
    /// @dev Property: Fees are always <= the amount out
    function capToken_redeem(uint256 _amountIn, uint256[] memory _minAmountsOut, address _receiver, uint256 _deadline)
        public
        updateGhosts
    {
        uint256 capTokenBalanceBefore = capToken.balanceOf(_getActor());
        uint256 totalCapSupplyBefore = capToken.totalSupply();
        (uint256[] memory expectedAmountsOut, uint256[] memory fees) = capToken.getRedeemAmount(_amountIn);

        vm.prank(_getActor());
        try capToken.redeem(_amountIn, _minAmountsOut, _receiver, _deadline) returns (uint256[] memory amountsOut) {
            // update variables for inlined properties
            uint256 capTokenBalanceAfter = capToken.balanceOf(_getActor());
            uint256 totalCapSupplyAfter = capToken.totalSupply();

            // update ghosts
            ghostAmountOut += _amountIn;

            // check inlined properties
            for (uint256 i = 0; i < _minAmountsOut.length; i++) {
                gte(amountsOut[i], _minAmountsOut[i], "user received less than minimum amount out");
            }

            for (uint256 i = 0; i < expectedAmountsOut.length; i++) {
                lte(fees[i], expectedAmountsOut[i], "fees are greater than the amount out");

                if (!IMinter(address(env.usdVault.capToken)).whitelisted(_getActor())) {
                    lte(amountsOut[i], expectedAmountsOut[i], "user received more than expected amount out");
                }
            }

            gte(
                totalCapSupplyBefore - totalCapSupplyAfter,
                capTokenBalanceBefore - capTokenBalanceAfter,
                "total cap supply decreased by less than the amount out"
            );
        } catch (bytes memory err) {
            bool expectedError = checkError(err, "InvalidMinAmountsOut()") || checkError(err, "PastDeadline()")
                || checkError(err, "Slippage(address,uint256,uint256)") || checkError(err, "InvalidAmount()")
                || checkError(err, "InsufficientReserves(address,uint256,uint256)")
                || checkError(err, "ERC20InvalidReceiver(address)");
            bool isProtocolPaused = capToken.paused();

            if (!expectedError && _amountIn > 0 && !isProtocolPaused) {
                lt(capTokenBalanceBefore, _amountIn, "user cannot redeem with sufficient cap token balance");
            }
        }
    }

    function capToken_removeAsset(address _asset) public updateGhosts asActor {
        capToken.removeAsset(_asset);
    }

    // @audit info: This function can only be called by the Lender contract to repay assets.
    // function capToken_repay(address _asset, uint256 _amount) public asActor {
    //     capToken.repay(_asset, _amount);
    // }

    function capToken_rescueERC20(address _asset, address _receiver) public updateGhosts asActor {
        capToken.rescueERC20(_asset, _receiver);
    }

    function capToken_setFeeData(address _asset, IMinter.FeeData memory _feeData) public updateGhosts asActor {
        capToken.setFeeData(_asset, _feeData);
    }

    function capToken_setFractionalReserveVault(address _asset, address _vault) public updateGhosts asActor {
        capToken.setFractionalReserveVault(_asset, _vault);
    }

    function capToken_setReserve(address _asset, uint256 _reserve) public updateGhosts asActor {
        capToken.setReserve(_asset, _reserve);
    }

    function capToken_setWhitelist(address _user, bool _whitelisted) public updateGhosts asActor {
        capToken.setWhitelist(_user, _whitelisted);
    }

    function capToken_transfer(address to, uint256 value) public updateGhosts asActor {
        capToken.transfer(to, value);
    }

    function capToken_transferFrom(address from, address to, uint256 value) public updateGhosts asActor {
        capToken.transferFrom(from, to, value);
    }

    function capToken_unpauseAsset(address _asset) public updateGhosts asActor {
        capToken.unpauseAsset(_asset);
    }

    function capToken_unpauseProtocol() public updateGhosts asActor {
        capToken.unpauseProtocol();
    }
}
