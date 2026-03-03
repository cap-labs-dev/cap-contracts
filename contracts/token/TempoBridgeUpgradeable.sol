// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ITIP20 } from "../interfaces/ITIP20.sol";
import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Tempo Bridge
/// @author kexley, Cap Labs
/// @notice A bridge using LayerZero for sending tokens to and from Tempo
contract TempoBridgeUpgradeable is OFTCoreUpgradeable, UUPSUpgradeable {
    /// @dev The underlying TIP20 token.
    ITIP20 internal immutable underlyingToken;

    /// @dev Constructor for the Tempo Bridge contract.
    /// @param _underlyingToken The address of the TIP20 token to bridge.
    /// @param _lzEndpoint The LayerZero endpoint address.
    constructor(address _underlyingToken, address _lzEndpoint)
        OFTCoreUpgradeable(ITIP20(_underlyingToken).decimals(), _lzEndpoint)
    {
        underlyingToken = ITIP20(_underlyingToken);
        _disableInitializers();
    }

    /// @dev Initialize the Tempo Bridge contract.
    /// @param _delegate The delegate address for OApp configuration.
    function initialize(address _delegate) external initializer {
        __OFTCore_init(_delegate);
        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
    }

    /// @notice Retrieves the address of the underlying TIP20 token.
    /// @return tokenAddress The address of the underlying TIP20 token.
    function token() public view returns (address tokenAddress) {
        tokenAddress = address(underlyingToken);
    }

    /// @notice Indicates whether approval is required to transfer tokens to the bridge for burning.
    /// @return requiresApproval Indicates whether approval is required.
    function approvalRequired() external pure virtual returns (bool requiresApproval) {
        requiresApproval = true;
    }

    /// @dev Burns tokens from the sender's balance to prepare for sending.
    /// @param _from The address to debit the tokens from.
    /// @param _amountLD The amount of tokens to send in local decimals.
    /// @param _minAmountLD The minimum amount to send in local decimals.
    /// @param _dstEid The destination chain ID.
    /// @return amountSentLD The amount sent in local decimals.
    /// @return amountReceivedLD The amount received in local decimals on the remote.
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        // Transfers tokens from the sender to the bridge since `burnFrom` is not supported on TIP20 tokens.
        underlyingToken.transferFrom(_from, address(this), amountSentLD);
        // Burn tokens from the bridge.
        underlyingToken.burn(amountSentLD);
    }

    /// @dev Mints tokens to the specified address.
    /// @param _to The address to credit the tokens to.
    /// @param _amountLD The amount of tokens to credit in local decimals.
    /// @dev _srcEid The source chain ID.
    /// @return amountReceivedLD The amount of tokens actually received in local decimals.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /* _srcEid */
    )
        internal
        virtual
        override
        returns (uint256 amountReceivedLD)
    {
        if (_to == address(0x0)) _to = address(0xdead); // _mint(...) does not support address(0x0)
        // Mints the tokens and transfers to the recipient.
        underlyingToken.mint(_to, _amountLD);
        // In the case of Tempo Bridge, the amountLD is equal to amountReceivedLD.
        return _amountLD;
    }

    /// @dev Authorize the upgrade
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
