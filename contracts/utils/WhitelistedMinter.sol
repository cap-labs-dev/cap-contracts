// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IVault } from "../interfaces/IVault.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WhitelistedMinter
/// @author Weso, Cap Labs
/// @notice Restricts cap token minting through a Vault to an owner-managed whitelist of callers
contract WhitelistedMinter is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Vault used to mint the cap token
    address public immutable capusd;

    /// @notice Whether an address is allowed to mint
    mapping(address => bool) public isWhitelisted;

    /// @notice Emitted when an address whitelist status changes
    /// @param account Address whose status changed
    /// @param status New whitelist status
    event WhitelistUpdated(address indexed account, bool status);

    /// @dev Thrown when a non-whitelisted address calls a restricted function
    error NotWhitelisted();

    /// @dev Thrown when the zero address is supplied where it is not allowed
    error ZeroAddress();

    /// @notice Restrict a function to whitelisted callers
    modifier onlyWhitelisted() {
        if (!isWhitelisted[msg.sender]) revert NotWhitelisted();
        _;
    }

    /// @param _capusd Address of the Vault used for minting
    constructor(address _capusd) Ownable(msg.sender) {
        if (_capusd == address(0)) revert ZeroAddress();
        capusd = _capusd;
    }

    /// @notice Mint the cap token using an asset on behalf of a whitelisted caller
    /// @dev Pulls `_amount` of `_asset` from the caller, approves the Vault, then mints to `_to`
    /// @param _asset Whitelisted asset to deposit
    /// @param _amount Amount of asset to use in the minting
    /// @param _minAmountOut Minimum amount of cap token to mint
    /// @param _to Receiver of the minted cap token
    /// @param _deadline Deadline for the minting
    /// @return amountOut Amount of cap token minted
    function mint(address _asset, uint256 _amount, uint256 _minAmountOut, address _to, uint256 _deadline)
        external
        onlyWhitelisted
        returns (uint256 amountOut)
    {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(_asset).forceApprove(capusd, _amount);
        amountOut = IVault(capusd).mint(_asset, _amount, _minAmountOut, _to, _deadline);
    }

    /// @notice Add a single address to the whitelist
    /// @param _address Address to whitelist
    function whitelist(address _address) external onlyOwner {
        isWhitelisted[_address] = true;
        emit WhitelistUpdated(_address, true);
    }

    /// @notice Add multiple addresses to the whitelist
    /// @param _addresses Addresses to whitelist
    function setWhitelist(address[] memory _addresses) external onlyOwner {
        for (uint256 i = 0; i < _addresses.length; i++) {
            isWhitelisted[_addresses[i]] = true;
            emit WhitelistUpdated(_addresses[i], true);
        }
    }

    /// @notice Remove multiple addresses from the whitelist
    /// @param _addresses Addresses to remove from the whitelist
    function removeWhitelist(address[] memory _addresses) external onlyOwner {
        for (uint256 i = 0; i < _addresses.length; i++) {
            isWhitelisted[_addresses[i]] = false;
            emit WhitelistUpdated(_addresses[i], false);
        }
    }
}
