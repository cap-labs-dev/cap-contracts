// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC7540AsyncRedeem } from "../interfaces/IERC7540AsyncRedeem.sol";
import { IERC7540Redeem } from "../interfaces/IERC7540Redeem.sol";
import { ERC7540AsyncRedeemStorageUtils } from "../storage/ERC7540AsyncRedeemStorageUtils.sol";
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
    ERC7540AsyncRedeemStorageUtils,
    ERC165Upgradeable
{
    using SafeERC20 for IERC20;

    /// @dev Initializer for ERC7540AsyncRedeem
    /// @param _asset The asset to be redeemed
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    /// @param _uri The URI for ERC1155 metadata
    function __ERC7540AsyncRedeem_init(IERC20 _asset, string memory _name, string memory _symbol, string memory _uri)
        internal
        onlyInitializing
    {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_asset);
        __ERC165_init();
        getERC7540AsyncRedeemStorage().queueNft = address(new ERC1155Queue(_uri));
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC7540 functions *****************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Request a redeem, shares are escrowed in this contract.
    /// @param _shares The number of shares to request for redeem
    /// @param _controller The controller of the request
    /// @param _owner The owner of the shares being redeemed
    /// @return requestId The id of the request
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId) {
        _checkAllowance(_owner, msg.sender, _shares);

        if (balanceOf(_owner) < _shares) revert ERC20InsufficientBalance(_owner, balanceOf(_owner), _shares);
        if (_shares == 0) revert ZeroShares();

        ERC7540AsyncRedeemStorage storage $ = getERC7540AsyncRedeemStorage();
        requestId = $.requestId;
        $.requestId++;

        $.queueIndex[requestId] = $.redeemQueue;
        $.redeemQueue += _shares;

        _transfer(_owner, address(this), _shares);
        IERC1155Queue($.queueNft).mint(_controller, requestId, _shares);

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @notice Withdraw assets from the vault after requesting a redeem.
    /// @param _requestId The id of the request
    /// @param _assets The number of assets to withdraw
    /// @param _receiver The receiver of the assets
    /// @param _controller The controller of the request
    /// @return shares The number of shares withdrawn
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

    /// @notice Redeem shares from the vault after requesting a redeem and it has been initiated
    /// @dev Shares are converted to assets at the exchange rate at the moment of redemption, not request.
    /// @param _requestId The id of the request
    /// @param _shares The number of shares to redeem
    /// @param _receiver The receiver of the assets
    /// @param _controller The controller of the request
    /// @return assets The number of assets redeemed
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

    /// @notice Get the number of claimable shares for a controller's request
    /// @param _requestId The id of the request
    /// @param _controller The controller of the request
    /// @return claimableShares The number of claimable shares
    function claimableRedeemRequest(uint256 _requestId, address _controller)
        public
        view
        returns (uint256 claimableShares)
    {
        ERC7540AsyncRedeemStorage storage $ = getERC7540AsyncRedeemStorage();
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

    /// @notice Get the number of pending shares for a controller's request
    /// @param _requestId The id of the request
    /// @param _controller The controller of the request
    /// @return pendingShares The number of pending shares
    function pendingRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 pendingShares)
    {
        ERC7540AsyncRedeemStorage storage $ = getERC7540AsyncRedeemStorage();
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

    /// @notice Get the maximum number of instantly redeemable shares
    /// @param _owner The owner of the shares
    /// @return maxShares The maximum number of instantly redeemable shares
    function maxRedeem(address _owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 maxShares) {
        uint256 instantUnlocked = instantUnlockedSupply();
        uint256 balance = balanceOf(_owner);
        maxShares = balance > instantUnlocked ? instantUnlocked : balance;
    }

    /// @notice Get the number of shares not in the redemption queue
    /// @return supply The number of shares not in the redemption queue
    function activeSupply() public view returns (uint256 supply) {
        supply = totalSupply() - redemptionQueue();
    }

    /// @notice Get the number of assets not in the redemption queue
    /// @return assets The number of assets not in the redemption queue
    function activeAssets() public view returns (uint256 assets) {
        assets = previewRedeem(activeSupply());
    }

    /// @notice Get the number of shares in the redemption queue
    /// @return queue The number of shares in the redemption queue
    function redemptionQueue() public view returns (uint256 queue) {
        ERC7540AsyncRedeemStorage storage $ = getERC7540AsyncRedeemStorage();
        queue = $.redeemQueue - $.settledQueue;
    }

    /// @notice Get the number of shares not locked
    /// @dev This function should be overridden
    /// @return unlocked The number of unlocked shares
    function unlockedSupply() public view virtual returns (uint256 unlocked) { }

    /// @notice Get the number of shares available to be instantly redeemed, taking into account the redemption queue
    /// @return unlocked The number of instantly unlocked shares
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

        ERC7540AsyncRedeemStorage storage $ = getERC7540AsyncRedeemStorage();
        $.queueIndex[_requestId] += _shares;
        $.settledQueue += _shares;
        IERC1155Queue($.queueNft).burn(_controller, _requestId, _shares);

        _burn(address(this), _shares);
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
        _transferOut(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    //////////////////////////////////////////////////////////////////////////////
    /**************************** ERC165 functions ******************************/
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Check if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return supported Whether the interface is supported
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IERC4626).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540AsyncRedeem).interfaceId || interfaceId == type(IERC1155Queue).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
