// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Stablecoin
/// @author kexley, Cap Labs
/// @notice The Stablecoin is a token that is backed by the underlying asset and can be used to borrow and repay debt.
contract Stablecoin layout at erc7201("cap.storage.Stablecoin")
    is
    IStablecoin,
    AccessManagedUpgradeable,
    ERC7540AsyncRedeem,
    UUPSUpgradeable
{
    using WadRayMath for uint256;

    /// @inheritdoc IStablecoin
    uint8 public underlyingDecimals;

    /// @inheritdoc IStablecoin
    address public irm;

    /// @inheritdoc IStablecoin
    uint256 public creditBackedSupply;

    /// @inheritdoc IStablecoin
    uint256 public badDebt;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IStablecoin
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
        underlyingDecimals = IERC20Metadata(_asset).decimals();
        irm = _irm;
    }

    /// @inheritdoc IStablecoin
    function mintCreditBacked(address _to, uint256 _amount) external restricted {
        _mint(_to, _amount);
        creditBackedSupply += _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit MintCreditBacked(_to, _amount);
    }

    /// @inheritdoc IStablecoin
    function burnCreditBacked(address _from, uint256 _amount) external restricted {
        _burn(_from, _amount);
        creditBackedSupply -= _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit BurnCreditBacked(_from, _amount);
    }

    /// @inheritdoc IStablecoin
    function utilizationRate() public view returns (uint256 rate) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        rate = creditBackedSupply.rayDiv(supply);
    }

    /// @inheritdoc IStablecoin
    function increaseBadDebt(uint256 _badDebt) external restricted {
        badDebt += _badDebt;
        emit BadDebtIncreased(_badDebt);
    }

    /// @inheritdoc IStablecoin
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IStablecoin) returns (uint256 unlocked) {
        unlocked = totalSupply() - creditBackedSupply;
    }

    /// @inheritdoc IStablecoin
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IStablecoin) returns (uint256 assets) {
        assets = totalSupply() - badDebt;
    }

    /// @inheritdoc IStablecoin
    function previewDeposit(uint256 _shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 assets)
    {
        assets =
            _shares * 10 ** underlyingDecimals / 10 ** decimals();
    }

    /// @inheritdoc IStablecoin
    function previewMint(uint256 _assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 shares)
    {
        shares =
            _assets * 10 ** decimals() / 10 ** underlyingDecimals;
    }

    /// @inheritdoc IStablecoin
    function decimals() public pure override(ERC4626Upgradeable, IERC20Metadata, IStablecoin) returns (uint8) {
        return 18;
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
        if (_shares < badDebt) {
            return super._convertToAssets(_shares, _rounding);
        } else {
            return (_shares - badDebt) * 10 ** underlyingDecimals / 10 ** decimals()
                + super._convertToAssets(badDebt, _rounding);
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
        uint256 badDebtInAssets = badDebt * 10 ** underlyingDecimals / 10 ** decimals();
        if (_assets < badDebtInAssets) {
            return super._convertToShares(_assets, _rounding);
        } else {
            return (_assets * 10 ** decimals() / 10 ** underlyingDecimals) - badDebt
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
        IInterestRateModel(irm).updateLiquidityRate();
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
        if (badDebt > 0) {
            uint256 reduced = _shares > badDebt ? badDebt : _shares;
            badDebt -= reduced;
            emit BadDebtReduced(_owner, reduced);
        }

        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
        IInterestRateModel(irm).updateLiquidityRate();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
