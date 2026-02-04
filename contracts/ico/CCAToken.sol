// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    EIP712Upgradeable,
    ERC20PermitUpgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Access } from "../access/Access.sol";
import { ICCAToken } from "../interfaces/ICCAToken.sol";
import { CCATokenStorageUtils } from "../storage/CCATokenStorageUtils.sol";

/// @title Continuous Clearing Auction Token
/// @author kexley, Cap Labs
/// @notice Token that is soul-bound unless the sender is whitelisted. Once the underlying asset address is set and fully funded on this
/// contract, CCA token holders can exchange their tokens 1:1 for the underlying asset.
/// @dev The admin must, a later date, set the asset address, directly transfer the required asset balance to this contract and unpause
/// the contract to enable exchange functionality. Exchange functionality is paused by default. The zap is integrated as the only address
/// that can receive CCA tokens from any address, but they must be exchanged in the same transaction or they will be locked in the zap
/// until another user exchanges them.
contract CCAToken is
    ICCAToken,
    UUPSUpgradeable,
    ERC20PermitUpgradeable,
    PausableUpgradeable,
    Access,
    CCATokenStorageUtils
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ICCAToken
    function initialize(address _accessControl, address _zap, string memory _name, string memory _symbol)
        external
        initializer
    {
        if (_accessControl == address(0)) revert ZeroAddressNotValid();
        __Access_init(_accessControl);
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_zap == address(0)) revert ZeroAddressNotValid();
        getCCATokenStorage().zap = _zap;
        _pause(); // pause exchange functionality by default
    }

    /// @inheritdoc ICCAToken
    function exchange(address _to, uint256 _amount) external whenNotPaused {
        _exchange(_msgSender(), _to, _amount);
    }

    /// @inheritdoc ICCAToken
    function exchangeFrom(address _from, address _to, uint256 _amount) external whenNotPaused {
        _spendAllowance(_from, _msgSender(), _amount);
        _exchange(_from, _to, _amount);
    }

    /// @inheritdoc ICCAToken
    function mint(address _to, uint256 _amount) external checkAccess(this.mint.selector) {
        if (_to == address(0)) revert ZeroAddressNotValid();
        if (_amount == 0) revert ZeroAmountNotValid();
        _mint(_to, _amount);
    }

    /// @inheritdoc ICCAToken
    function burn(uint256 _amount) external checkAccess(this.burn.selector) {
        _burn(_msgSender(), _amount);
    }

    /// @inheritdoc ICCAToken
    function pause() external checkAccess(this.pause.selector) {
        _pause();
    }

    /// @inheritdoc ICCAToken
    function recoverERC20(address _token, address _to, uint256 _amount)
        external
        checkAccess(this.recoverERC20.selector)
    {
        if (_token == address(0)) revert ZeroAddressNotValid();
        if (_to == address(0)) revert ZeroAddressNotValid();
        if (_amount == 0) revert ZeroAmountNotValid();
        IERC20(_token).safeTransfer(_to, _amount);
        emit RecoveredERC20(_token, _to, _amount);
    }

    /// @inheritdoc ICCAToken
    function setAsset(address _asset) external checkAccess(this.setAsset.selector) {
        if (_asset == address(0)) revert ZeroAddressNotValid();
        getCCATokenStorage().asset = _asset;
        emit SetAsset(_asset);
    }

    /// @inheritdoc ICCAToken
    function setWhitelist(address _user, bool _whitelisted) external checkAccess(this.setWhitelist.selector) {
        if (_user == zap()) revert ZapAddressCannotBeWhitelisted();
        getCCATokenStorage().whitelist[_user] = _whitelisted;
        emit SetWhitelist(_user, _whitelisted);
    }

    /// @inheritdoc ICCAToken
    function unpause() external checkAccess(this.unpause.selector) {
        _unpause();
    }

    /// @inheritdoc ICCAToken
    function asset() public view returns (address assetAddress) {
        assetAddress = getCCATokenStorage().asset;
    }

    /// @inheritdoc ICCAToken
    function whitelisted(address _user) public view returns (bool isWhitelisted) {
        isWhitelisted = getCCATokenStorage().whitelist[_user];
    }

    /// @inheritdoc ICCAToken
    function zap() public view returns (address zapAddress) {
        zapAddress = getCCATokenStorage().zap;
    }

    /// @inheritdoc ERC20Upgradeable
    function name() public pure override returns (string memory) {
        return "Cap Redeemable Token";
    }

    /// @inheritdoc EIP712Upgradeable
    function _EIP712Name() internal pure override returns (string memory) {
        return "Cap Redeemable Token";
    }

    /// @dev Exchange CCA tokens for the asset at a 1:1 value
    /// @param _from Sender address
    /// @param _to Receiver address
    /// @param _amount Amount of tokens to exchange
    function _exchange(address _from, address _to, uint256 _amount) internal {
        address token = asset();
        if (token == address(0)) revert AssetNotSet();
        if (IERC20(token).balanceOf(address(this)) < totalSupply()) revert InsufficientBalance();
        if (_amount == 0) revert ZeroAmountNotValid();

        _burn(_from, _amount);
        IERC20(token).safeTransfer(_to, _amount);
        emit Exchanged(_from, _to, _amount);
    }

    /// @dev Override to check if sender is whitelisted unless minting, burning, or exchanging with zap.
    /// The zap address itself cannot send CCA tokens after receiving them, they must be exchanged.
    /// @param from Sender address
    /// @param to Receiver address
    /// @param value Amount of tokens
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !whitelisted(from) && to != zap()) revert TransferNotAllowed();

        super._update(from, to, value);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
