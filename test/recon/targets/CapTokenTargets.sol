// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
import { vm } from "@chimera/Hevm.sol";
import { console2 } from "forge-std/console2.sol";

// Helpers

import { OpType } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";

import { ERC4626 } from "../mocks/MockERC4626Tester.sol";
import { MockERC20 } from "@recon/MockERC20.sol";
import { Panic } from "@recon/Panic.sol";
import { IMinter } from "contracts/interfaces/IMinter.sol";

import "contracts/token/CapToken.sol";

abstract contract CapTokenTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function capToken_mint_clamped(uint256 _amountIn) public {
        capToken_mint(_amountIn, 0, block.timestamp + 1 days);
    }

    function capToken_burn_clamped(uint256 _amountIn) public {
        capToken_burn(_amountIn, 0, block.timestamp + 1 days);
    }

    function capToken_redeem_clamped(uint256 _amountIn) public {
        uint256[] memory _minAmountsOut = new uint256[](3);
        _minAmountsOut[0] = 0; // Set minimum amount out to 0 for clamping
        _minAmountsOut[1] = 0; // Set minimum amount out to 0 for clamping
        _minAmountsOut[2] = 0; // Set minimum amount out to 0 for clamping
        capToken_redeem(_amountIn, _minAmountsOut, _getActor(), block.timestamp + 1 days);
    }

    /// HELPER FUNCTIONS ///
    function _validateMintAssetValue(address _asset, uint256 _cusdMinted, uint256 _assetsReceived) internal {
        (uint256 assetPrice,) = oracle.getPrice(_asset);
        (uint256 capPrice,) = oracle.getPrice(address(capToken));

        if (assetPrice >= 0.85e8 && assetPrice <= 1.05e8) {
            uint256 assetDecimals = MockERC20(_asset).decimals();
            uint256 assetValueReceived = _assetsReceived * assetPrice * 1e18 / (10 ** assetDecimals * 1e8);
            gte(assetValueReceived, _cusdMinted * capPrice / 1e8, "minted cUSD is less than the asset value received");
        }
    }

    function _validateBurnAssetValue(address _asset, uint256 _cusdBurned, uint256 _assetsReceived) internal {
        (uint256 assetPrice,) = oracle.getPrice(_asset);
        (uint256 capPrice,) = oracle.getPrice(address(capToken));

        if (assetPrice >= 0.85e8 && assetPrice <= 1.05e8) {
            uint256 assetDecimals = MockERC20(_asset).decimals();
            uint256 assetValueReceived = _assetsReceived * assetPrice * 1e18 / (10 ** assetDecimals * 1e8);
            lte(assetValueReceived, _cusdBurned * capPrice / 1e8, "burner received more asset value than cUSD burned");
        }
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function capToken_addAsset() public updateGhosts asActor {
        capToken.addAsset(_getAsset());
    }

    function capToken_approve(address spender, uint256 value) public asActor {
        bool value0;
        try capToken.approve(spender, value) returns (bool tempValue0) {
            value0 = tempValue0;
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "ERC20InvalidSpender(address)");
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
    /// @dev Property: Burning reduces cUSD supply, must always round down
    /// @dev Property: Burners must not receive more asset value than cUSD burned
    function capToken_burn(uint256 _amountIn, uint256 _minAmountOut, uint256 _deadline) public updateGhosts {
        uint256 capTokenBalanceBefore = capToken.balanceOf(_getActor());
        uint256 insuranceFundBalanceBefore = MockERC20(_getAsset()).balanceOf(capToken.insuranceFund());
        uint256 totalCapSupplyBefore = capToken.totalSupply();
        uint256 assetBalanceBefore = MockERC20(_getAsset()).balanceOf(_getActor());
        (uint256 expectedAmountOut,) = capToken.getBurnAmount(_getAsset(), _amountIn);

        vm.prank(_getActor());
        try capToken.burn(_getAsset(), _amountIn, _minAmountOut, _getActor(), _deadline) {
            // update variables for inlined properties
            uint256 capTokenBalanceAfter = capToken.balanceOf(_getActor());
            uint256 insuranceFundBalanceAfter = MockERC20(_getAsset()).balanceOf(capToken.insuranceFund());
            uint256 totalCapSupplyAfter = capToken.totalSupply();
            uint256 assetBalanceAfter = MockERC20(_getAsset()).balanceOf(_getActor());

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
            if (!capToken.whitelisted(_getActor())) {
                lte(
                    capTokenBalanceAfter,
                    capTokenBalanceBefore - expectedAmountOut,
                    "user received more than expected amount out"
                );
            }

            // for optimization property, set the new value if the amount out is greater than the current max and there are no fees
            if (
                int256(capTokenBalanceBefore - capTokenBalanceAfter) > maxAmountOut
                    && (insuranceFundBalanceAfter - insuranceFundBalanceBefore) == 0
            ) {
                maxAmountOut = int256(capTokenBalanceBefore - capTokenBalanceAfter);
            }

            if (assetBalanceAfter - assetBalanceBefore > 0) {
                _validateBurnAssetValue(_getAsset(), _amountIn, assetBalanceAfter - assetBalanceBefore);
            }
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "PastDeadline()")
                || checkError(reason, "Slippage(address,uint256,uint256)") || checkError(reason, "InvalidAmount()")
                || checkError(reason, "AssetNotSupported(address)")
                || checkError(reason, "InsufficientReserves(address,uint256,uint256)")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)");
            bool isPaused = capToken.paused();
            if (!expectedError && _amountIn > 0 && !isPaused) {
                lt(capTokenBalanceBefore, _amountIn, "user cannot burn with sufficient cap token balance");
            }
        }
    }

    /// @dev Property: ERC4626 must always be divestable
    function capToken_divestAll() public asActor {
        try capToken.divestAll(_getAsset()) { }
        catch (bytes memory reason) {
            bool expectedError = checkError(reason, "LossFromFractionalReserve(address,address,uint256)")
                || checkError(reason, "AccessControlUnauthorizedAccount(address,bytes32)");
            if (!expectedError) {
                t(false, "ERC4626 must always be divestable");
            }
        }
    }

    function capToken_investAll() public updateGhostsWithType(OpType.INVEST) asActor {
        capToken.investAll(_getAsset());
    }

    /// @dev Property: User always receives at least the minimum amount out
    /// @dev Property: Fees are always <= the amount out
    /// @dev Property: Fees are always nonzero when minting
    /// @dev Property: User always receives at most the expected amount out
    /// @dev Property: Asset cannot be minted when it is paused
    /// @dev Property: User can always mint cap token if they have sufficient balance of depositing asset
    /// @dev Property: Minting increases vault assets based on oracle value.
    function capToken_mint(uint256 _amountIn, uint256 _minAmountOut, uint256 _deadline) public updateGhosts {
        uint256 assetBalance = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 capTokenBalanceBefore = capToken.balanceOf(_getActor());
        uint256 insuranceFundBalanceBefore = capToken.balanceOf(capToken.insuranceFund());
        uint256 totalSuppliesBefore = capToken.totalSupplies(_getAsset());
        (uint256 expectedAmountOut, uint256 mintFee) = capToken.getMintAmount(_getAsset(), _amountIn);
        bool isAssetPaused = capToken.paused(_getAsset());

        vm.prank(_getActor());
        try capToken.mint(_getAsset(), _amountIn, _minAmountOut, _getActor(), _deadline) returns (uint256 amountOut) {
            uint256 capTokenBalanceAfter = capToken.balanceOf(_getActor());
            uint256 insuranceFundBalanceAfter = capToken.balanceOf(capToken.insuranceFund());

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

            if (capTokenBalanceAfter > capTokenBalanceBefore) {
                _validateMintAssetValue(_getAsset(), amountOut, _amountIn);
            }
            if (!capToken.whitelisted(_getActor())) {
                // NOTE: temporarily removed because we need a better check for mint fee using price deviation
                // if (insuranceFundBalanceAfter != 0) {
                //     gt(insuranceFundBalanceAfter - insuranceFundBalanceBefore, 0, "0 fees when minting");
                // }

                lte(
                    capTokenBalanceAfter,
                    capTokenBalanceBefore + expectedAmountOut,
                    "user received more than expected amount out"
                );
            }

            t(!isAssetPaused, "asset can be minted when it is paused");
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "PastDeadline()")
                || checkError(reason, "Slippage(address,uint256,uint256)") || checkError(reason, "InvalidAmount()")
                || checkError(reason, "AssetNotSupported(address)") || checkError(reason, "ERC20InvalidReceiver(address)");
            bool isProtocolPaused = capToken.paused();
            bool enoughAllowance = MockERC20(_getAsset()).allowance(_getActor(), address(capToken)) >= _amountIn;
            if (!expectedError && _amountIn > 0 && enoughAllowance && !isProtocolPaused && !isAssetPaused) {
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

                if (!capToken.whitelisted(_getActor())) {
                    lte(amountsOut[i], expectedAmountsOut[i], "user received more than expected amount out");
                }
            }

            gte(
                totalCapSupplyBefore - totalCapSupplyAfter,
                capTokenBalanceBefore - capTokenBalanceAfter,
                "total cap supply decreased by less than the amount out"
            );
        } catch (bytes memory reason) {
            bool expectedError = checkError(reason, "InvalidMinAmountsOut()") || checkError(reason, "PastDeadline()")
                || checkError(reason, "Slippage(address,uint256,uint256)") || checkError(reason, "InvalidAmount()")
                || checkError(reason, "InsufficientReserves(address,uint256,uint256)")
                || checkError(reason, "ERC20InvalidReceiver(address)")
                || checkError(reason, "LossFromFractionalReserve(address,address,uint256)");
            bool isProtocolPaused = capToken.paused();
            bool hasEnoughBalance = capTokenBalanceBefore >= _amountIn;
            bool hasEnoughAllowance = capToken.allowance(_getActor(), address(capToken)) >= _amountIn;

            if (!expectedError && _amountIn > 0 && hasEnoughBalance && hasEnoughAllowance && !isProtocolPaused) {
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

    function capToken_setFractionalReserveVault() public updateGhosts asActor {
        capToken.setFractionalReserveVault(address(ERC4626(_getVault()).asset()), _getVault());
    }

    function capToken_setReserve(uint256 _reserve) public updateGhosts asActor {
        _reserve %= uint256(type(uint88).max);
        capToken.setReserve(_getAsset(), _reserve);
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
