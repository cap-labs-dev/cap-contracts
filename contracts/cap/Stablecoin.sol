// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { StablecoinStorageUtils } from "../storage/StablecoinStorageUtils.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Stablecoin
/// @author kexley
/// @notice The Stablecoin is a token that is backed by the underlying asset and can be used to borrow and repay debt.
contract Stablecoin is
    IStablecoin,
    AccessManagedUpgradeable,
    ERC7540AsyncRedeem,
    StablecoinStorageUtils,
    UUPSUpgradeable
{
    using WadRayMath for uint256;

    /// @notice Initialize the stablecoin
    /// @param _authority The address of the authority
    /// @param _asset The address of the underlying asset
    /// @param _name The name of the stablecoin token
    /// @param _symbol The symbol of the stablecoin token
    /// @param _uri The URI of the ERC1155 redemption receipt tokens
    /// @param _irm The address of the interest rate model
    function initialize(
        address _authority,
        address _asset,
        string memory _name,
        string memory _symbol,
        string memory _uri,
        address _irm
    ) external initializer {
        __AccessManaged_init(_authority);
        __ERC7540AsyncRedeem_init(IERC20Metadata(_asset), _name, _symbol, _uri);
        Storage storage $ = getStablecoinStorage();
        $.underlyingDecimals = IERC20Metadata(_asset).decimals();
        $.irm = _irm;
    }

    /// @notice Mint unbacked shares as part of a borrow or reward
    /// @param _to The address of the receiver
    /// @param _amount The amount of shares minted
    function mintUnbacked(address _to, uint256 _amount) external restricted {
        _mint(_to, _amount);
        Storage storage $ = getStablecoinStorage();
        $.unbacked += _amount;
        IInterestRateModel($.irm).update();
    }

    /// @notice Burn unbacked shares as part of a repayment or liquidation
    /// @param _from The address of the sender
    /// @param _amount The amount of shares burned
    function burnUnbacked(address _from, uint256 _amount) external restricted {
        _burn(_from, _amount);
        Storage storage $ = getStablecoinStorage();
        $.unbacked -= _amount;
        IInterestRateModel($.irm).update();
    }

    /// @notice Get the utilization rate of the Stablecoin
    /// @return rate The utilization rate of the cUSD
    function utilizationRate() public view returns (uint256 rate) {
        Storage storage $ = getStablecoinStorage();
        rate = $.unbacked.rayDiv(totalSupply());
    }

    /// @notice Increase the current bad debt to instantly socialize losses
    /// @param _badDebt The amount of bad debt to increase
    function increaseBadDebt(uint256 _badDebt) external restricted {
        Storage storage $ = getStablecoinStorage();
        $.badDebt += _badDebt;
    }

    /// @notice Get the remaining bad debt
    /// @return debt The remaining bad debt
    function badDebt() public view returns (uint256 debt) {
        Storage storage $ = getStablecoinStorage();
        debt = $.badDebt;
    }

    /// @notice Get the number of shares available to be redeemed
    /// @return unlocked The number of unlocked shares
    function unlockedSupply() public view override returns (uint256 unlocked) {
        Storage storage $ = getStablecoinStorage();
        unlocked = totalSupply() - $.unbacked;
    }

    /// @notice Get the total assets of the Stablecoin, minus any bad debt
    /// @return assets The total assets of the Stablecoin
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() - getStablecoinStorage().badDebt;
    }

    /// @notice Preview override for 1:1 deposits
    /// @param _shares The number of shares to convert to assets
    /// @return assets The number of assets
    function previewDeposit(uint256 _shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 assets)
    {
        assets = _shares * 10 ** underlyingDecimals() / 10 ** decimals();
    }

    /// @notice Preview override for 1:1 mints
    /// @param _assets The number of assets to convert to shares
    /// @return shares The number of shares
    function previewMint(uint256 _assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 shares) {
        shares = _assets * 10 ** decimals() / 10 ** underlyingDecimals();
    }

    /// @notice Override the decimals function to return 18
    /// @return 18 The number of decimals
    function decimals() public pure override(ERC4626Upgradeable, IERC20Metadata) returns (uint8) {
        return 18;
    }

    /// @notice Get the decimals of the underlying asset
    /// @return decimals The decimals of the underlying asset
    function underlyingDecimals() public view returns (uint8) {
        return getStablecoinStorage().underlyingDecimals;
    }

    /// @dev Override conversion to handle bad debt during withdrawals
    /// @param _shares The number of shares to convert to assets
    /// @param _rounding The rounding direction
    /// @return assets The number of assets
    function _convertToAssets(uint256 _shares, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 assets)
    {
        Storage storage $ = getStablecoinStorage();
        if (_shares < $.badDebt) {
            return super._convertToAssets(_shares, _rounding);
        } else {
            return (_shares - $.badDebt) * 10 ** underlyingDecimals() / 10 ** decimals()
                + super._convertToAssets($.badDebt, _rounding);
        }
    }

    /// @dev Override conversion to handle bad debt during withdrawals
    /// @param _assets The number of assets to convert to shares
    /// @param _rounding The rounding direction
    /// @return shares The number of shares
    function _convertToShares(uint256 _assets, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 shares)
    {
        Storage storage $ = getStablecoinStorage();
        uint256 badDebtInAssets = $.badDebt * 10 ** underlyingDecimals() / 10 ** decimals();
        if (_assets < badDebtInAssets) {
            return super._convertToShares(_assets, _rounding);
        } else {
            return (_assets * 10 ** decimals() / 10 ** underlyingDecimals()) - $.badDebt
                + super._convertToShares(badDebtInAssets, _rounding);
        }
    }

    /// @dev Override the internal deposit function to update the IRM
    /// @param _caller The address of the caller
    /// @param _receiver The address of the receiver
    /// @param _assets The amount of assets deposited
    /// @param _shares The amount of shares minted
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        super._deposit(_caller, _receiver, _assets, _shares);
        IInterestRateModel(getStablecoinStorage().irm).update();
    }

    /// @dev Override the internal withdraw function to update the bad debt and IRM. Bad debt is absorbed proportionally
    /// by the first redeemers until it is fully absorbed and peg is restored.
    /// @param _caller The address of the caller
    /// @param _receiver The address of the receiver
    /// @param _owner The address of the owner
    /// @param _assets The amount of assets withdrawn
    /// @param _shares The amount of shares burned
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
    {
        Storage storage $ = getStablecoinStorage();
        if ($.badDebt > 0) {
            if (_shares > $.badDebt) {
                $.badDebt = 0;
            } else {
                $.badDebt -= _shares;
            }
        }
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
        IInterestRateModel(getStablecoinStorage().irm).update();
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** UUPS functions ********************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Authorize the upgrade
    function _authorizeUpgrade(address) internal override restricted { }
}
