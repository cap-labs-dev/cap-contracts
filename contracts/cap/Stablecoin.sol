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
        // both previews scale between the two units, and only the direction that divides can lose
        // anything. Below 18 that is the mint side, which rounds up so the vault keeps the dust;
        // above 18 it would be the deposit side, where rounding up is not available because the
        // assets have already been pulled, and a deposit too small to mint a single share would
        // simply be donated. Refuse the configuration rather than carry a preview that cannot
        // round in the vault's favour
        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        if (assetDecimals > decimals()) revert UnsupportedDecimals();
        underlyingDecimals = assetDecimals;
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
        rate = _utilizationRate(creditBackedSupply, totalSupply());
    }

    /// @inheritdoc IStablecoin
    function utilizationRateAfterMint(uint256 _amount) public view returns (uint256 rate) {
        rate = _utilizationRate(creditBackedSupply + _amount, totalSupply() + _amount);
    }

    /// @inheritdoc IStablecoin
    function supplies() public view returns (uint256 credit, uint256 supply) {
        credit = creditBackedSupply;
        supply = totalSupply();
    }

    /// @dev Shared so that the projection cannot drift from the live figure it projects
    /// @param _credit The credit-backed supply
    /// @param _supply The total supply
    /// @return rate The utilization rate in ray decimals
    function _utilizationRate(uint256 _credit, uint256 _supply) internal pure returns (uint256 rate) {
        if (_supply == 0) return 0;
        rate = _credit.rayDiv(_supply);
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
        shares = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IStablecoin
    /// @dev At par while bad debt is outstanding; see {previewDeposit}.
    ///
    /// Rounded up, as ERC-4626 requires of the side that quotes what a mint costs. Truncating here
    /// hands out shares for nothing whenever the requested amount does not divide the scale
    /// exactly, which against a six decimal underlying is anything below 1e12 wei of cUSD. The
    /// amounts are dust, but the reserve identity the redemption gate rests on is not something to
    /// leave standing on a rounding direction.
    function previewMint(uint256 _shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 assets)
    {
        assets = Math.mulDiv(_shares, 10 ** underlyingDecimals, 10 ** decimals(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IStablecoin
    function decimals() public pure override(ERC4626Upgradeable, IERC20Metadata, IStablecoin) returns (uint8) {
        return 18;
    }

    /// @dev While a shortfall is outstanding, redemptions are priced below the pool's own backing
    /// ratio, so exiting repairs the peg for whoever stays instead of passing the loss on. The gap
    /// the redeemer leaves is burned off the bad debt in {_onWithdraw}.
    ///
    /// The shares that stay retain `remaining * supply * backing / (supply * backing + remaining *
    /// shortfall)` and the redeemer takes the rest, which works out at `backing` squared over
    /// `supply * backing + remaining * shortfall`, per share. So a whole-supply exit is paid the
    /// backing ratio exactly, and the marginal redeemer that ratio squared, with everything in
    /// between on the curve joining them. Repair is asymptotic by construction, since the haircut
    /// has to fade out as the shortfall does or there would be a cliff at the moment it cleared,
    /// so {coverBadDebt} is what closes the gap outright.
    ///
    /// Charging under the ratio is what makes exiting first the worst time to exit, which is the
    /// point: during a shortfall the incentive runs towards waiting rather than racing for the
    /// door. Nobody gets that improvement for free, since it only arrives once another holder has
    /// actually left and taken the haircut. Pricing at the flat ratio would leave exit timing
    /// neutral instead, and hand the loss to whoever was still holding at the end.
    ///
    /// None of it can be gamed by chopping a redemption up, because the curve conserves
    /// `shortfall / (supply * backing)`. Call that `k`: retaining `remaining / (1 + k * remaining)`
    /// depends on nothing but the remaining supply and `k`, and a redemption leaves `k` where it
    /// found it, so every route from one supply to another arrives at the same payout. Splitting,
    /// batching, and interleaving with other people's redemptions are exactly equal, not equal up
    /// to dust. That invariant is the thing to test against.
    ///
    /// Only this side is bad debt aware. {previewDeposit} and {previewMint} bypass it to mint at
    /// par; see {previewDeposit} for why. Depositing to improve an exit does not work either:
    /// minting at par lowers `k`, but by less than the par mint costs.
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
