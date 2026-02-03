// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { Access } from "../access/Access.sol";
import { IStabledrop } from "../interfaces/IStabledrop.sol";
import { StabledropStorageUtils } from "../storage/StabledropStorageUtils.sol";

/// @title Stabledrop
/// @author kexley, Cap Labs
/// @notice Stabledrop contract for claiming stables with Merkle proofs
/// @dev Admin must fund the stabledrop and unpause to enable public claiming. Hashed user addresses and
/// amounts are used as leaves in the Merkle tree. The root can be updated to add more claims without
/// allowing double claims. Only the claimant or approved operators can claim their stabledrop.
contract Stabledrop is IStabledrop, UUPSUpgradeable, PausableUpgradeable, Access, StabledropStorageUtils {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IStabledrop
    function initialize(address _accessControl, bytes32 _root, address _token) external initializer {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);
        __Pausable_init();
        __UUPSUpgradeable_init();
        _pause(); // pause claiming by default

        getStabledropStorage().root = _root;
        getStabledropStorage().token = _token;
    }

    /// @inheritdoc IStabledrop
    function approveOperator(address _operator, bool _approved) external {
        getStabledropStorage().approved[msg.sender][_operator] = _approved;
        emit ApproveOperator(msg.sender, _operator, _approved);
    }

    /// @inheritdoc IStabledrop
    function approveOperatorFor(address _claimant, address _operator, bool _approved)
        external
        checkAccess(this.approveOperatorFor.selector)
    {
        if (_claimant == address(0) || _operator == address(0)) revert ZeroAddressNotValid();
        getStabledropStorage().approved[_claimant][_operator] = _approved;
        emit ApproveOperator(_claimant, _operator, _approved);
    }

    /// @inheritdoc IStabledrop
    function claim(address _claimant, address _recipient, uint256 _amount, bytes32[] calldata _proofs)
        external
        whenNotPaused
    {
        StabledropStorage storage $ = getStabledropStorage();

        // only the claimant or approved operators can claim
        if (_claimant != msg.sender && !$.approved[_claimant][msg.sender]) revert NotOwnerOrOperator();
        if (_recipient == address(0)) revert ZeroAddressNotValid();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(_claimant, _amount))));
        if (!MerkleProof.verifyCalldata(_proofs, $.root, leaf)) revert InvalidProof();

        // prevent reentrancy
        if (_amount <= $.claimed[_claimant]) revert NothingToClaim();
        uint256 toSend = _amount - $.claimed[_claimant];
        $.totalClaimed += toSend;
        $.claimed[_claimant] = _amount;

        if (IERC20($.token).balanceOf(address(this)) < toSend) revert InsufficientBalance();
        IERC20($.token).safeTransfer(_recipient, toSend);
        emit Claim(_claimant, _recipient, toSend);
    }

    /// @inheritdoc IStabledrop
    function fund(uint256 _amount) external {
        StabledropStorage storage $ = getStabledropStorage();
        IERC20($.token).safeTransferFrom(msg.sender, address(this), _amount);
        emit Fund(_amount);
    }

    /// @inheritdoc IStabledrop
    function setRoot(bytes32 _root) external checkAccess(this.setRoot.selector) {
        getStabledropStorage().root = _root;
        emit SetRoot(_root);
    }

    /// @inheritdoc IStabledrop
    function recoverERC20(address _token, address _to, uint256 _amount)
        external
        checkAccess(this.recoverERC20.selector)
    {
        if (_token == address(0) || _to == address(0)) {
            revert ZeroAddressNotValid();
        }
        IERC20(_token).safeTransfer(_to, _amount);
        emit RecoverERC20(_token, _to, _amount);
    }

    /// @inheritdoc IStabledrop
    function pause() external checkAccess(this.pause.selector) {
        _pause();
    }

    /// @inheritdoc IStabledrop
    function unpause() external checkAccess(this.unpause.selector) {
        _unpause();
    }

    /// @inheritdoc IStabledrop
    function approved(address _claimant, address _operator) external view returns (bool) {
        return getStabledropStorage().approved[_claimant][_operator];
    }

    /// @inheritdoc IStabledrop
    function claimed(address _claimant) external view returns (uint256) {
        return getStabledropStorage().claimed[_claimant];
    }

    /// @inheritdoc IStabledrop
    function root() external view returns (bytes32) {
        return getStabledropStorage().root;
    }

    /// @inheritdoc IStabledrop
    function token() external view returns (address) {
        return getStabledropStorage().token;
    }

    /// @inheritdoc IStabledrop
    function totalClaimed() external view returns (uint256) {
        return getStabledropStorage().totalClaimed;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
