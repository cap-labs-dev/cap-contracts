// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IPredicateClient } from "@predicate/interfaces/IPredicateClient.sol";

/// @title IValidationHook
/// @notice Interface for the validation hook
/// @author kexley, Cap Labs
interface IValidationHook is IPredicateClient {
    /// @custom:storage-location erc7201:cap.storage.ValidationHook
    /// @dev Validation hook storage
    /// @param auction Auction address
    /// @param token ERC721 token address
    /// @param gateUntil Time gate timestamp
    struct ValidationHookStorage {
        address auction;
        address token;
        uint256 gate;
    }

    /// @notice Error thrown when the caller is not the auction
    error CallerMustBeAuction();

    /// @notice Error thrown when the attestation is invalid
    error InvalidAttestation();

    /// @notice Error thrown when the gate timestamp is invalid
    error InvalidGate();

    /// @notice Error thrown when the sender is not the owner of the required ERC721 token
    error NotOwnerOfERC721Token();

    /// @notice Error thrown when the sender is not the owner of the bid
    error SenderMustBeOwner();

    /// @notice Error thrown when the zero address is not valid
    error ZeroAddressNotValid();

    /// @notice Event emitted when an attestation is validated
    /// @param sender The sender of the transaction
    /// @param uuid The UUID of the attestation
    event AttestationValidated(address indexed sender, string uuid);

    /// @notice Initialize the validation hook
    /// @param _accessControl Access control address
    /// @param _token ERC721 token address
    /// @param _gate Time gate timestamp
    /// @param _registry Predicate registry address
    /// @param _policyID Predicate policy ID
    function initialize(
        address _accessControl,
        address _token,
        uint256 _gate,
        address _registry,
        string memory _policyID
    ) external;

    /// @notice Validate a bid
    /// @dev MUST revert if the bid is invalid
    /// @param _maxPrice The maximum price the bidder is willing to pay
    /// @param _amount The amount of the bid
    /// @param _owner The owner of the bid
    /// @param _sender The sender of the bid
    /// @param _hookData Additional data to pass to the hook required for validation
    function validate(uint256 _maxPrice, uint128 _amount, address _owner, address _sender, bytes calldata _hookData)
        external;

    /// @notice Set the auction address
    /// @dev This function can be called by the admin to change the auction address
    /// @param _auction Auction address
    function setAuction(address _auction) external;

    /// @notice Set the ERC721 token address
    /// @dev This function can be called by the admin to change the required ERC721 token address
    /// @param _token ERC721 token address
    function setToken(address _token) external;

    /// @notice Set the gate timestamp, can be set in the past to allow for immediate validation
    /// @dev This function can be called by the admin to change the time gate, even to the past to allow for immediate validation
    /// @param _gate Time gate timestamp
    function setGate(uint256 _gate) external;

    /// @notice Get the auction address
    /// @return . The auction address
    function auction() external view returns (address);

    /// @notice Get the ERC721 token address
    /// @return . The ERC721 token address
    function token() external view returns (address);

    /// @notice Get the time gate timestamp
    /// @return . The time gate timestamp
    function gate() external view returns (uint256);
}
