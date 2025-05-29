// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IMinter } from "../interfaces/IMinter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20, ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { OAppMessenger } from "./OAppMessenger.sol";

/// @title PreMainnetVault
/// @author @capLabs
/// @notice Vault for pre-mainnet campaign
/// @dev Underlying asset is deposited on this contract and LayerZero is used to bridge across a
/// minting message to the testnet. The campaign has a maximum timestamp after which transfers are
/// enabled to prevent the owner from unduly locking assets.
contract PreMainnetVault is ERC20Permit, OAppMessenger {
    using SafeERC20 for IERC20Metadata;
    using SafeERC20 for IERC4626;

    /// @notice Underlying asset
    IERC20Metadata public immutable asset;

    /// @notice Cap
    IVault public immutable cap;

    /// @notice Staked Cap
    IERC4626 public immutable stakedCap;

    /// @notice Underlying asset decimals
    uint8 private immutable assetDecimals;

    /// @notice Maximum end timestamp for the campaign after which transfers are enabled
    uint256 public immutable maxCampaignEnd;

    /// @dev Bool for if the transfers are unlocked before the campaign ends
    bool private unlocked;

    /// @dev Zero amounts are not allowed for minting
    error ZeroAmount();

    /// @dev Zero addresses are not allowed for minting
    error ZeroAddress();

    /// @dev Transfers not yet enabled
    error TransferNotEnabled();

    /// @dev The campaign has ended
    error CampaignEnded();

    /// @dev Deposit underlying asset and get shares
    event Deposit(address indexed user, uint256 underlyingAmount, uint256 shares);

    /// @dev Withdraw redeem shares and get staked cap
    event Withdraw(address indexed user, uint256 stakedCapAmount);

    /// @dev Transfers enabled
    event TransferEnabled();

    /// @dev Initialize the token with the underlying asset and bridge info
    /// @param _asset Underlying asset
    /// @param _cap Cap
    /// @param _stakedCap Staked cap
    /// @param _lzEndpoint Local layerzero endpoint
    /// @param _dstEid Destination lz EID
    /// @param _maxCampaignLength Max campaign length in seconds
    constructor(
        address _asset,
        address _cap,
        address _stakedCap,
        address _lzEndpoint,
        uint32 _dstEid,
        uint256 _maxCampaignLength
    )
        ERC20("Boosted cUSD", "bcUSD")
        ERC20Permit("Boosted cUSD")
        OAppMessenger(_lzEndpoint, _dstEid, IERC20Metadata(_asset).decimals())
        Ownable(msg.sender)
    {
        asset = IERC20Metadata(_asset);
        cap = IVault(_cap);
        stakedCap = IERC4626(_stakedCap);
        assetDecimals = asset.decimals();
        maxCampaignEnd = block.timestamp + _maxCampaignLength;

        IERC20Metadata(address(asset)).forceApprove(address(cap), type(uint256).max);
        IERC20Metadata(address(cap)).forceApprove(address(stakedCap), type(uint256).max);
    }

    /// @notice Deposit underlying asset to mint cUSD on MegaETH Testnet
    /// @param _amount Amount of underlying asset to deposit
    /// @param _minShares Minimum amount of shares to mint
    /// @param _destReceiver Receiver of the assets on MegaETH Testnet
    /// @param _refundAddress The address to receive any excess fee values sent to the endpoint if the call fails on the destination chain
    /// @param _deadline Deadline for the deposit
    /// @return shares Amount of staked cap minted
    function deposit(
        uint256 _amount,
        uint256 _minShares,
        address _destReceiver,
        address _refundAddress,
        uint256 _deadline
    ) external payable returns (uint256 shares) {
        if (_amount == 0) revert ZeroAmount();
        if (_destReceiver == address(0)) revert ZeroAddress();

        if (transferEnabled()) revert CampaignEnded();

        asset.safeTransferFrom(msg.sender, address(this), _amount);

        shares = _depositIntoStakedCap(_amount, _minShares, _deadline);

        _mint(msg.sender, shares);

        _sendMessage(_destReceiver, _amount, _refundAddress);

        emit Deposit(msg.sender, _amount, shares);
    }

    /// @dev Preview deposit
    /// @param _amount Amount of underlying asset to deposit
    /// @return shares Amount of shares minted
    function previewDeposit(uint256 _amount) external view returns (uint256 shares) {
        (uint256 amountOut,) = IMinter(address(cap)).getMintAmount(address(asset), _amount);
        shares = stakedCap.previewDeposit(amountOut);
    }

    /// @dev Deposit into staked cap
    /// @param _amount Amount of underlying asset to deposit
    /// @param _minShares Minimum amount of shares to mint
    /// @param _deadline Deadline for the deposit
    /// @return shares Amount of shares minted
    function _depositIntoStakedCap(uint256 _amount, uint256 _minShares, uint256 _deadline)
        internal
        returns (uint256 shares)
    {
        uint256 amountOut = cap.mint(address(asset), _amount, _minShares, address(this), _deadline);

        return stakedCap.deposit(amountOut, address(this));
    }

    /// @notice Withdraw staked cap after campaign ends
    /// @param _amount Amount of staked cap to withdraw
    /// @param _receiver Receiver of the withdrawn underlying assets
    function withdraw(uint256 _amount, address _receiver) external {
        if (_amount == 0) revert ZeroAmount();
        if (_receiver == address(0)) revert ZeroAddress();

        _burn(msg.sender, _amount);

        stakedCap.safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Override decimals to return decimals of underlying asset
    /// @return decimals Asset decimals
    function decimals() public view override returns (uint8) {
        return assetDecimals;
    }

    /// @notice Transfers enabled
    /// @return enabled Bool for whether transfers are enabled
    function transferEnabled() public view returns (bool enabled) {
        enabled = unlocked || block.timestamp > maxCampaignEnd;
    }

    /// @notice Enable transfers before campaign ends
    function enableTransfer() external onlyOwner {
        unlocked = true;
        emit TransferEnabled();
    }

    /// @dev Override _update to disable transfer before campaign ends
    /// @param _from From address
    /// @param _to To address
    /// @param _value Amount to transfer
    function _update(address _from, address _to, uint256 _value) internal override {
        if (!transferEnabled() && _from != address(0)) revert TransferNotEnabled();
        super._update(_from, _to, _value);
    }
}
