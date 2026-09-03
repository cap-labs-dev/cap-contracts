// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "../interfaces/IERC7540AsyncRedeem.sol";
import { IERC7540Redeem } from "../interfaces/IERC7540Redeem.sol";
import { ERC1155Queue, IERC1155Queue } from "./ERC1155Queue.sol";
import { ERC7540Operator, IERC7540Operator } from "./ERC7540Operator.sol";
import { ERC7575, IERC7575 } from "./ERC7575.sol";
import {
    ERC4626Upgradeable,
    IERC4626
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ERC7540AsyncRedeem
/// @author kexley
/// @notice ERC7540AsyncRedeem is a contract that implements the ERC7540 standard for async redemptions.
/// @dev The function unlockedSupply() should be overridden to return the number of shares available for redemption.
/// @dev Preview ERC4626 functions are NOT reverting as instant redemptions are supported when there is liquidity. Integrators must implement ERC1155Holder to request async redemptions.
abstract contract ERC7540AsyncRedeem is
    IERC7540AsyncRedeem,
    ERC7540Operator,
    ERC4626Upgradeable,
    ERC7575,
    ERC165Upgradeable
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location cap.storage.ERC7540AsyncRedeem
    // forge-lint: disable-next-item(pascal-case-struct)
    struct ERC7540AsyncRedeemStorage {
        uint256 requestId;
        uint256 redeemQueue;
        uint256 settledQueue;
        mapping(uint256 => uint256) queueIndex;
        address queueNft;
    }

    // keccak256(abi.encode(uint256(keccak256("cap.storage.ERC7540AsyncRedeem")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev ERC-7201 storage slot for ERC7540AsyncRedeem
    uint256 private constant STORAGE_LOCATION = 0x8bbfa7ffdb3d5e8e16606d7fe820f66c6f836f8f0a57a0e300a31d3eca5c0300;

    /// @dev Get the storage of the contract
    /// @return $ The storage of the contract
    // forge-lint: disable-next-item(mixed-case-function)
    function _getERC7540AsyncRedeemStorage() private pure returns (ERC7540AsyncRedeemStorage storage $) {
        uint256 slot = STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    /// @dev Initializer for ERC7540AsyncRedeem
    /// @param _asset The asset to be redeemed
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    /// @param _uri The URI for ERC1155 metadata
    // forge-lint: disable-next-item(mixed-case-function)
    function __ERC7540AsyncRedeem_init(IERC20 _asset, string memory _name, string memory _symbol, string memory _uri)
        internal
        onlyInitializing
    {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_asset);
        __ERC165_init();
        _getERC7540AsyncRedeemStorage().queueNft = address(new ERC1155Queue(_uri));
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC7540 functions *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC7540AsyncRedeem
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId) {
        _checkAllowance(_owner, msg.sender, _shares);

        if (balanceOf(_owner) < _shares) revert ERC20InsufficientBalance(_owner, balanceOf(_owner), _shares);
        if (_shares == 0) revert ZeroShares();

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        requestId = $.requestId;
        $.requestId++;

        $.queueIndex[requestId] = $.redeemQueue;
        $.redeemQueue += _shares;

        _transfer(_owner, address(this), _shares);
        IERC1155Queue($.queueNft).mint(_controller, requestId, _shares);

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function withdraw(uint256 _requestId, uint256 _assets, address _receiver, address _controller)
        public
        virtual
        returns (uint256 shares)
    {
        shares = previewWithdraw(_assets);
        uint256 maxShares = claimableRedeemRequest(_requestId, _controller);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(_controller, shares, maxShares);

        _withdraw(msg.sender, _receiver, _controller, _assets, shares, _requestId);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function redeem(uint256 _requestId, uint256 _shares, address _receiver, address _controller)
        public
        virtual
        returns (uint256 assets)
    {
        uint256 maxShares = claimableRedeemRequest(_requestId, _controller);
        if (_shares > maxShares) revert ERC4626ExceededMaxRedeem(_controller, _shares, maxShares);
        assets = previewRedeem(_shares);

        _withdraw(msg.sender, _receiver, _controller, assets, _shares, _requestId);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function claimableRedeemRequest(uint256 _requestId, address _controller)
        public
        view
        returns (uint256 claimableShares)
    {
        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        uint256 currentIndex = $.settledQueue + unlockedSupply();
        uint256 queueIndex = $.queueIndex[_requestId];
        uint256 balance = IERC1155Queue($.queueNft).balanceOf(_controller, _requestId);

        if (currentIndex <= queueIndex) {
            claimableShares = 0;
        } else if (currentIndex >= queueIndex + balance) {
            claimableShares = balance;
        } else {
            claimableShares = currentIndex - queueIndex;
        }
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function pendingRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 pendingShares)
    {
        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        uint256 currentIndex = $.settledQueue + unlockedSupply();
        uint256 queueIndex = $.queueIndex[_requestId];
        uint256 balance = IERC1155Queue($.queueNft).balanceOf(_controller, _requestId);

        if (currentIndex >= queueIndex + balance) {
            pendingShares = 0;
        } else if (currentIndex <= queueIndex) {
            pendingShares = balance;
        } else {
            pendingShares = queueIndex + balance - currentIndex;
        }
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address _owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 maxShares) {
        uint256 instantUnlocked = instantUnlockedSupply();
        uint256 balance = balanceOf(_owner);
        maxShares = balance > instantUnlocked ? instantUnlocked : balance;
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function activeSupply() public view returns (uint256 supply) {
        supply = totalSupply() - redemptionQueue();
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function activeAssets() public view returns (uint256 assets) {
        assets = previewRedeem(activeSupply());
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function redemptionQueue() public view returns (uint256 queue) {
        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        queue = $.redeemQueue - $.settledQueue;
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function unlockedSupply() public view virtual returns (uint256 unlocked) { }

    /// @inheritdoc IERC7540AsyncRedeem
    function instantUnlockedSupply() public view returns (uint256 unlocked) {
        uint256 totalUnlocked = unlockedSupply();
        uint256 queue = redemptionQueue();
        if (totalUnlocked > queue) unlocked = totalUnlocked - queue;
    }

    /// @dev Internal function to check if the caller is the controller or an authorized operator, or spend allowance for the shares
    /// @param _controller The controller of the request
    /// @param _caller The caller of the request
    function _checkAllowance(address _controller, address _caller, uint256 _shares) internal {
        if (_caller != _controller && !isOperator(_controller, _caller)) {
            _spendAllowance(_controller, _caller, _shares);
        }
    }

    /// @dev Internal function to withdraw assets from the vault after requesting a redeem
    /// @param _caller The caller of the withdraw
    /// @param _receiver The receiver of the assets
    /// @param _controller The controller of the request
    /// @param _assets The number of assets to withdraw
    /// @param _shares The number of shares to withdraw
    /// @param _requestId The id of the request
    function _withdraw(
        address _caller,
        address _receiver,
        address _controller,
        uint256 _assets,
        uint256 _shares,
        uint256 _requestId
    ) internal virtual {
        _checkAllowance(_controller, _caller, _shares);

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        $.queueIndex[_requestId] += _shares;
        $.settledQueue += _shares;
        IERC1155Queue($.queueNft).burn(_controller, _requestId, _shares);

        _burn(address(this), _shares);
        _onWithdraw(_controller, _assets, _shares);
        _transferOut(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _controller, _assets, _shares);
    }

    /// @dev Override the ERC4626 _withdraw function to enable the ERC7540Operator to withdraw assets
    /// @param _caller The caller of the withdraw
    /// @param _receiver The receiver of the assets
    /// @param _owner The owner of the shares
    /// @param _assets The number of assets to withdraw
    /// @param _shares The number of shares to withdraw
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        virtual
        override
    {
        _checkAllowance(_owner, _caller, _shares);

        _burn(_owner, _shares);
        _onWithdraw(_owner, _assets, _shares);
        _transferOut(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /// @dev Settle accounting that every redemption shares, whichever path it took. Both instant
    /// and queued redemptions route through here, which is the only place they meet: the queued
    /// path cannot reuse the instant one because it burns from this contract rather than from the
    /// owner, so anything overriding only that would silently skip the whole queue.
    ///
    /// Runs after the burn, so the new supply is visible, and before {_transferOut}, so an asset
    /// token that calls back finds the accounting already settled.
    /// @param _owner The account whose shares were burned, or the controller of a queued request
    /// @param _assets The number of assets being paid out
    /// @param _shares The number of shares burned
    function _onWithdraw(address _owner, uint256 _assets, uint256 _shares) internal virtual { }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC165 functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IERC4626).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540AsyncRedeem).interfaceId || interfaceId == type(IERC1155Queue).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
