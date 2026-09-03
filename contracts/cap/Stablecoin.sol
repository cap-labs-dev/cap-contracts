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
    function recognizeBadDebt(uint256 _amount) external restricted {
        badDebt += _amount;
        // the borrower will never repay, so this cUSD will never be burned by {burnCreditBacked}.
        // Leaving it counted would hold `creditBackedSupply` permanently too high.
        //
        // Removing it does not make it redeemable: {unlockedSupply} subtracts `creditBackedSupply`
        // and `badDebt` together, and `badDebt` just rose by the same amount, so the total held
        // back is unchanged. Holders bear the loss through {totalAssets}, which nets off `badDebt`
        // so that each share redeems below par.
        creditBackedSupply -= _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit BadDebtRecognized(_amount);
    }

    /// @inheritdoc IStablecoin
    function coverBadDebt(uint256 _amount) external restricted returns (uint256 covered) {
        uint256 shortfall = badDebt;
        if (shortfall == 0) revert NoBadDebt();
        covered = _amount < shortfall ? _amount : shortfall;

        // supply and shortfall fall together, so totalAssets is unchanged and the same backing now
        // stands behind fewer shares. The reserve is untouched: this retires written off supply
        // rather than adding new deposits
        badDebt = shortfall - covered;
        _burn(msg.sender, covered);

        IInterestRateModel(irm).updateLiquidityRate();
        emit BadDebtCovered(msg.sender, covered);
    }

    /// @inheritdoc IStablecoin
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IStablecoin) returns (uint256 unlocked) {
        // credit-backed supply is a claim on borrowers rather than on the deposits held here, and
        // written off supply is a claim on nothing at all. Neither may redeem against the reserve.
        uint256 locked = creditBackedSupply + badDebt;
        uint256 supply = totalSupply();
        if (supply > locked) unlocked = supply - locked;
    }

    /// @inheritdoc IStablecoin
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IStablecoin) returns (uint256 assets) {
        assets = totalSupply() - badDebt;
    }

    /// @inheritdoc IStablecoin
    /// @dev Deliberately at par even while bad debt is outstanding, rather than at the backing
    /// ratio, and markets rely on this. Minting at the ratio would let anyone turn a dollar into
    /// more than a dollar of cUSD, which a liquidator could burn against debt at face value to
    /// collect `1 + bonus` of collateral on cUSD they conjured for less, and that excess would
    /// come straight out of the underwriters. Holding the mint at par caps the cost of acquiring
    /// cUSD at a dollar, so a liquidation can never release more collateral than the liquidator
    /// paid for plus the intended bonus. It also means new deposits top the reserve back up, at
    /// the cost of the depositor taking a share of the outstanding shortfall when they leave.
    function previewDeposit(uint256 _assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 shares)
    {
        shares =
            _assets * 10 ** decimals() / 10 ** underlyingDecimals;
    }

    /// @inheritdoc IStablecoin
    /// @dev At par while bad debt is outstanding; see {previewDeposit}
    function previewMint(uint256 _shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 assets)
    {
        assets =
            _shares * 10 ** underlyingDecimals / 10 ** decimals();
    }

    /// @inheritdoc IStablecoin
    function decimals() public pure override(ERC4626Upgradeable, IERC20Metadata, IStablecoin) returns (uint8) {
        return 18;
    }

    /// @dev While a shortfall is outstanding, redemptions are priced below the pool's own backing
    /// ratio, so exiting repairs the peg for whoever stays instead of passing the loss on. The gap
    /// the redeemer leaves is burned off the bad debt in {_onWithdraw}.
    ///
    /// The shortfall retires in proportion to the supply redeemed, so taking out a tenth of the
    /// shares retires a tenth of `badDebt / totalAssets`. That proportionality is what makes the
    /// price independent of how a redemption is chopped up: pricing off the ratio at each instant
    /// would let a large exit split into slices and harvest its own repair, since every slice
    /// lifts the ratio for the next. This is the limit of that process charged upfront, so
    /// splitting and batching agree up to rounding dust.
    ///
    /// The shares that stay retain `remaining * supply * backing / (supply * backing + remaining *
    /// shortfall)`, and the redeemer takes the rest: linear in size for ordinary redemptions, and
    /// exactly `totalAssets` once the whole supply exits. Repair is asymptotic by construction,
    /// since the haircut has to fade out as the shortfall does or there would be a cliff at the
    /// moment it cleared, so {coverBadDebt} is what closes the gap outright.
    ///
    /// Only this side is bad debt aware. {previewDeposit} and {previewMint} bypass it to mint at
    /// par; see {previewDeposit} for why.
    /// @param _shares The number of shares to convert to assets
    /// @param _rounding The rounding direction
    /// @return assets The number of assets
    function _convertToAssets(uint256 _shares, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 assets)
    {
        uint256 shortfall = badDebt;
        uint256 value;
        if (shortfall == 0) {
            value = _shares;
        } else {
            uint256 supply = totalSupply();
            uint256 backing = totalAssets();
            if (_shares >= supply) {
                value = backing;
            } else {
                uint256 remaining = supply - _shares;
                uint256 anchor = supply * backing;
                // the payout is backing less what is retained, so the retained side is rounded the
                // opposite way to keep the payout itself on the requested side
                uint256 retained = Math.mulDiv(remaining, anchor, anchor + remaining * shortfall, _opposite(_rounding));
                value = backing > retained ? backing - retained : 0;
            }
        }
        assets = Math.mulDiv(value, 10 ** underlyingDecimals, 10 ** decimals(), _rounding);
    }

    /// @dev Inverse of {_convertToAssets}, solving the same curve for the shares that must burn to
    /// leave a given payout. Exact rather than approximate, so a redeem and a withdraw of the same
    /// size agree.
    /// @param _assets The number of assets to convert to shares
    /// @param _rounding The rounding direction
    /// @return shares The number of shares
    function _convertToShares(uint256 _assets, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 shares)
    {
        if (_assets == 0) return 0;
        uint256 value = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals, _rounding);
        uint256 shortfall = badDebt;
        if (shortfall == 0) return value;

        uint256 supply = totalSupply();
        uint256 backing = totalAssets();
        // more than the whole reserve can ever pay out, so the entire supply would not cover it
        if (value >= backing) return supply;

        uint256 retained = backing - value;
        uint256 anchor = supply * backing;
        uint256 remaining = Math.mulDiv(retained, anchor, anchor - retained * shortfall, _opposite(_rounding));
        shares = supply > remaining ? supply - remaining : 0;
    }

    /// @dev Flip a rounding direction, for the intermediate terms that are subtracted rather than
    /// returned. Rounding those up is what rounds the final result down.
    /// @param _rounding The rounding direction to invert
    /// @return flipped The opposite rounding direction
    function _opposite(Math.Rounding _rounding) private pure returns (Math.Rounding flipped) {
        flipped = _rounding == Math.Rounding.Ceil ? Math.Rounding.Floor : Math.Rounding.Ceil;
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

    /// @dev Retire the shortfall this redemption absorbed and refresh the rate. Whatever the
    /// redeemer left on the table relative to their share count burns off the bad debt, which is
    /// what lifts the backing ratio for the remaining supply. Deriving it from the assets actually
    /// paid is what keeps `totalAssets` exact: it falls by precisely that payout, so no part of
    /// the loss can be erased from the accounting or counted twice.
    ///
    /// This hangs off {ERC7540AsyncRedeem-_onWithdraw} rather than `_withdraw` so that queued
    /// redemptions retire their share too. Overriding `_withdraw` reaches only the instant path,
    /// which would leave every queued redeemer paying the haircut without the shortfall ever
    /// falling, so exiting would push the ratio down for whoever stayed and the difference would
    /// strand in the reserve with nothing left to claim it.
    /// @param _owner The address whose shares were burned
    /// @param _assets The amount of assets withdrawn
    /// @param _shares The amount of shares burned
    function _onWithdraw(address _owner, uint256 _assets, uint256 _shares) internal override {
        if (badDebt > 0) {
            uint256 paidInShares = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals);
            uint256 reduced = _shares > paidInShares ? _shares - paidInShares : 0;
            if (reduced > badDebt) reduced = badDebt;
            badDebt -= reduced;
            emit BadDebtReduced(_owner, reduced);
        }

        IInterestRateModel(irm).updateLiquidityRate();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
