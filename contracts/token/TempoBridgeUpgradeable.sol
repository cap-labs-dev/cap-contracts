// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ITIP20 } from "../interfaces/ITIP20.sol";
import { OFTAltCoreUpgradeable } from "@layerzerolabs/oft-alt-evm/contracts/OFTAltCoreUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Tempo Bridge
/// @author kexley, Cap Labs
/// @notice A bridge using LayerZero for sending tokens to and from Tempo
contract TempoBridgeUpgradeable is OFTAltCoreUpgradeable, UUPSUpgradeable {
    struct TempoBridgeStorage {
        // The underlying TIP20 token.
        ITIP20 underlyingToken;
    }

    // keccak256(abi.encode(uint256(keccak256("cap.storage.TempoBridge")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TempoBridgeStorageLocation =
        0xaff443d40d9449d0bb041d5986df9cd3a11be6e711f780b1d135421cee639900;

    /// @dev Get the tempo bridge storage.
    /// @return $ Storage pointer
    function _getTempoBridgeStorage() internal pure returns (TempoBridgeStorage storage $) {
        assembly {
            $.slot := TempoBridgeStorageLocation
        }
    }

    /// @dev Constructor for the Tempo Bridge contract. All TIP20 tokens have 6 decimals.
    /// @param _lzEndpoint The LayerZero endpoint address.
    constructor(address _lzEndpoint) OFTAltCoreUpgradeable(6, _lzEndpoint) {
        _disableInitializers();
    }

    /// @dev Initialize the Tempo Bridge contract.
    /// @param _underlyingToken The address of the TIP20 token to bridge.
    /// @param _delegate The delegate address for OApp configuration.
    function initialize(address _underlyingToken, address _delegate) external initializer {
        _getTempoBridgeStorage().underlyingToken = ITIP20(_underlyingToken);
        __OFTAltCore_init(_delegate);
        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
    }

    /// @notice Retrieves the address of the underlying TIP20 token.
    /// @return tokenAddress The address of the underlying TIP20 token.
    function token() public view returns (address tokenAddress) {
        tokenAddress = address(_getTempoBridgeStorage().underlyingToken);
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
        ITIP20 underlyingToken = _getTempoBridgeStorage().underlyingToken;
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
        _getTempoBridgeStorage().underlyingToken.mint(_to, _amountLD);
        // In the case of Tempo Bridge, the amountLD is equal to amountReceivedLD.
        return _amountLD;
    }

    /// @dev Authorize the upgrade
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
