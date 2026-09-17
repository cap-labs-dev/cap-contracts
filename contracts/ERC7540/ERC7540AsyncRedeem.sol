// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "../interfaces/IERC7540AsyncRedeem.sol";
import { IERC7540Redeem } from "../interfaces/IERC7540Redeem.sol";
import { IERC7575 } from "../interfaces/IERC7575.sol";
import { ERC7540Operator, IERC7540Operator } from "./ERC7540Operator.sol";
import {
    ERC4626Upgradeable,
    IERC4626
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ERC7540AsyncRedeem
/// @author kexley
/// @notice ERC7540 async redemptions on an ERC4626 vault
/// @dev Override {unlockedSupply}. Instant exits are {instantRedeem}/{instantWithdraw}.
abstract contract ERC7540AsyncRedeem is IERC7540AsyncRedeem, ERC7540Operator, ERC4626Upgradeable, ERC165 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location cap.storage.ERC7540AsyncRedeem
    // forge-lint: disable-next-item(pascal-case-struct)
    struct ERC7540AsyncRedeemStorage {
        uint256 requestId;
        uint256 redeemQueue;
        uint256 settledQueue;
        mapping(uint256 => uint256) queueIndex;
        mapping(uint256 => uint256) requestShares;
        mapping(uint256 => address) requestController;
        mapping(address => EnumerableSet.UintSet) controllerRequests;
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
    // forge-lint: disable-next-item(mixed-case-function)
    function __ERC7540AsyncRedeem_init(IERC20 _asset, string memory _name, string memory _symbol)
        internal
        onlyInitializing
    {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_asset);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function share() public view virtual returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId) {
        if (_controller == address(0)) revert ZeroAddress();
        _checkAllowance(_owner, msg.sender, _shares);

        if (balanceOf(_owner) < _shares) revert ERC20InsufficientBalance(_owner, balanceOf(_owner), _shares);
        if (_shares == 0) revert ZeroShares();

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        // ERC-7540: if any request returns id 0, every request must. Nonzero ids start at 1.
        requestId = ++$.requestId;

        $.queueIndex[requestId] = $.redeemQueue;
        $.requestShares[requestId] = _shares;
        $.requestController[requestId] = _controller;
        $.controllerRequests[_controller].add(requestId);
        _transfer(_owner, address(this), _shares);
        $.redeemQueue += _shares;

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function transferRequest(uint256 _requestId, address _to) external {
        if (_to == address(0)) revert ZeroAddress();

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        address from = $.requestController[_requestId];
        if ($.requestShares[_requestId] == 0) revert RedeemRequestNotFound(_requestId, from);
        _checkController(from, msg.sender);
        if (_to == from) return;

        $.requestController[_requestId] = _to;
        $.controllerRequests[from].remove(_requestId);
        $.controllerRequests[_to].add(_requestId);

        emit TransferRequest(from, _to, _requestId);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    /// @dev Cap extra, not an ERC-7540 method. Needed once requests can move between controllers.
    function controllerOf(uint256 _requestId) public view returns (address controller) {
        controller = _getERC7540AsyncRedeemStorage().requestController[_requestId];
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function requestsOf(address controller) external view returns (uint256[] memory requestIds) {
        requestIds = _getERC7540AsyncRedeemStorage().controllerRequests[controller].values();
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function withdraw(uint256 _requestId, uint256 _assets, address _receiver, address _controller)
        public
        virtual
        returns (uint256 shares)
    {
        _checkController(_controller, msg.sender);
        shares = _quoteWithdraw(_assets);
        uint256 maxShares = claimableRedeemRequest(_requestId, _controller);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(_controller, shares, maxShares);

        _claim(_receiver, _controller, _assets, shares, _requestId);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function redeem(uint256 _requestId, uint256 _shares, address _receiver, address _controller)
        public
        virtual
        returns (uint256 assets)
    {
        _checkController(_controller, msg.sender);
        uint256 maxShares = claimableRedeemRequest(_requestId, _controller);
        if (_shares > maxShares) revert ERC4626ExceededMaxRedeem(_controller, _shares, maxShares);
        assets = convertToAssets(_shares);

        _claim(_receiver, _controller, assets, _shares, _requestId);
    }

    /// @notice Claim previously requested redemptions for `controller`, oldest request first
    /// @dev Replaces the ERC-4626 instant-balance redeem. Caller must be `controller` or its
    /// operator; ERC-20 allowance is insufficient. Limited to currently claimable shares
    /// and {unlockedSupply}. Pays `convertToAssets(shares)` once (floored), then consumes
    /// receipts to match; per-request floors cannot underpay. Dust transferred onto this
    /// controller is cleared the same way: redeem the claimable dust and the receipts drop
    /// off the FIFO walk.
    /// @param _shares Shares to claim
    /// @param _receiver Asset recipient
    /// @param _controller Request controller, not an instant share-balance owner
    /// @return assets Assets paid
    function redeem(uint256 _shares, address _receiver, address _controller)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 assets)
    {
        uint256 maxShares = maxRedeem(_controller);
        if (_shares > maxShares) revert ERC4626ExceededMaxRedeem(_controller, _shares, maxShares);
        assets = convertToAssets(_shares);
        _claimFifo(_shares, _receiver, _controller, assets);
    }

    /// @notice Claim previously requested redemptions for `controller` by asset amount, oldest first
    /// @dev Replaces the ERC-4626 instant-balance withdraw. Caller must be `controller` or its
    /// operator; ERC-20 allowance is insufficient. Limited to currently claimable shares
    /// and {unlockedSupply}. Burns the ceil-quoted shares and pays `_assets` once.
    /// @param _assets Assets to pay
    /// @param _receiver Asset recipient
    /// @param _controller Request controller, not an instant share-balance owner
    /// @return shares Shares burned
    function withdraw(uint256 _assets, address _receiver, address _controller)
        public
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = _quoteWithdraw(_assets);
        uint256 maxShares = maxRedeem(_controller);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxWithdraw(_controller, _assets, convertToAssets(maxShares));
        }
        _claimFifo(shares, _receiver, _controller, _assets);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function instantRedeem(uint256 _shares, address _receiver, address _owner) public virtual returns (uint256 assets) {
        uint256 maxShares = maxInstantRedeem(_owner);
        if (_shares > maxShares) revert ERC4626ExceededMaxRedeem(_owner, _shares, maxShares);
        assets = convertToAssets(_shares);
        _withdraw(msg.sender, _receiver, _owner, assets, _shares);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function instantWithdraw(uint256 _assets, address _receiver, address _owner)
        public
        virtual
        returns (uint256 shares)
    {
        shares = _quoteWithdraw(_assets);
        uint256 maxShares = maxInstantRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxWithdraw(_owner, _assets, maxInstantWithdraw(_owner));
        }
        _withdraw(msg.sender, _receiver, _owner, _assets, shares);
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev Capped by {unlockedSupply}. `settledQueue` is total claimed, not a contiguous
    /// prefix, so a later 4-arg claim must not keep an earlier request claimable after liquidity
    /// falls. Liquidity is still allocated FIFO via the watermark; already-claimable shares may
    /// settle out of order. Pending is the remainder of the request.
    function claimableRedeemRequest(uint256 _requestId, address _controller)
        public
        view
        returns (uint256 claimableShares)
    {
        claimableShares = _claimableShares(_requestId, _controller);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 pendingShares)
    {
        pendingShares = _requestShares(_requestId, _controller) - _claimableShares(_requestId, _controller);
    }

    /// @notice Claimable shares across `controller`'s requests, not an instant share balance
    /// @dev Sum of {claimableRedeemRequest} for that controller, capped by {unlockedSupply}.
    /// A Cap {ITranche} may revert {ITranche-InvalidPrice} when that cap needs a price.
    /// @param _controller Request controller, not an instant share-balance owner
    /// @return maxShares Currently claimable shares
    function maxRedeem(address _controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxShares)
    {
        uint256 unlocked = unlockedSupply();
        if (unlocked == 0) return 0;

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        EnumerableSet.UintSet storage ids = $.controllerRequests[_controller];
        uint256 n = ids.length();
        for (uint256 i; i < n; ++i) {
            maxShares += _claimableShares(ids.at(i), _controller);
            if (maxShares >= unlocked) return unlocked;
        }
    }

    /// @notice Asset quote of {maxRedeem} for `controller`
    /// @dev `convertToAssets` of the claimable share limit (floored). Not a withdraw from the
    /// owner's share balance. A Cap {ITranche} may revert {ITranche-InvalidPrice} when
    /// {maxRedeem} needs a price.
    /// @param _controller Request controller, not an instant share-balance owner
    /// @return maxAssets Currently claimable assets
    function maxWithdraw(address _controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 maxAssets)
    {
        maxAssets = convertToAssets(maxRedeem(_controller));
    }

    /// @notice Async redeem vaults do not support {previewRedeem}
    /// @dev Reverts {PreviewNotSupported}. Use {convertToAssets} or {quoteWithdraw}.
    function previewRedeem(uint256) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @notice Async redeem vaults do not support {previewWithdraw}
    /// @dev Reverts {PreviewNotSupported}. Use {quoteWithdraw}.
    function previewWithdraw(uint256) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function quoteWithdraw(uint256 assets) public view returns (uint256 shares) {
        shares = _quoteWithdraw(assets);
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function maxInstantRedeem(address _owner) public view returns (uint256 maxShares) {
        uint256 instantUnlocked = instantUnlockedSupply();
        uint256 balance = balanceOf(_owner);
        maxShares = balance > instantUnlocked ? instantUnlocked : balance;
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function maxInstantWithdraw(address _owner) public view returns (uint256 maxAssets) {
        maxAssets = convertToAssets(maxInstantRedeem(_owner));
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function activeSupply() public view returns (uint256 supply) {
        supply = totalSupply() - redemptionQueue();
    }

    /// @inheritdoc IERC7540AsyncRedeem
    function activeAssets() public view returns (uint256 assets) {
        assets = convertToAssets(activeSupply());
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

    /// @dev Controller, operator, or spend share allowance.
    /// @param _controller The controller of the request
    /// @param _caller The caller of the request
    /// @param _shares The shares the caller is spending allowance against
    function _checkAllowance(address _controller, address _caller, uint256 _shares) internal {
        if (_caller != _controller && !isOperator(_controller, _caller)) {
            _spendAllowance(_controller, _caller, _shares);
        }
    }

    /// @dev Controller or operator only. Allowance cannot stand in.
    /// @param _controller The controller of the request
    /// @param _caller The caller of the claim
    function _checkController(address _controller, address _caller) internal view {
        if (_caller != _controller && !isOperator(_controller, _caller)) revert NotAuthorized(_caller);
    }

    /// @dev Remaining shares on `requestId` if `controller` owns it.
    /// @param _requestId The request id
    /// @param _controller The controller to match
    /// @return shares The remaining requested shares
    function _requestShares(uint256 _requestId, address _controller) internal view returns (uint256 shares) {
        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        if ($.requestController[_requestId] == _controller) shares = $.requestShares[_requestId];
    }

    /// @dev FIFO watermark slice of a request, capped by current {unlockedSupply}.
    /// @param _requestId The request id
    /// @param _controller The controller to match
    /// @return claimableShares Shares that may be claimed now
    function _claimableShares(uint256 _requestId, address _controller) internal view returns (uint256 claimableShares) {
        uint256 balance = _requestShares(_requestId, _controller);
        if (balance == 0) return 0;

        uint256 unlocked = unlockedSupply();
        if (unlocked == 0) return 0;

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        uint256 currentIndex = $.settledQueue + unlocked;
        uint256 queueIndex = $.queueIndex[_requestId];

        if (currentIndex <= queueIndex) {
            return 0;
        } else if (currentIndex >= queueIndex + balance) {
            claimableShares = balance;
        } else {
            claimableShares = currentIndex - queueIndex;
        }
        if (claimableShares > unlocked) claimableShares = unlocked;
    }

    /// @dev Shares a withdrawal of `assets` would burn. Ceil, matching the old {previewWithdraw}.
    /// @param assets The asset amount
    /// @return shares The share amount
    function _quoteWithdraw(uint256 assets) internal view returns (uint256 shares) {
        shares = _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @dev Consume `_shares` from the controller's requests, oldest id first,
    /// then pay `_assets` once. Fragment conversions are not used.
    /// @param _shares The shares to consume
    /// @param _receiver The asset recipient
    /// @param _controller The request controller
    /// @param _assets The assets to pay
    function _claimFifo(uint256 _shares, address _receiver, address _controller, uint256 _assets) internal {
        _checkController(_controller, msg.sender);
        if (_shares == 0) {
            if (_assets != 0) revert InexactPayout(0, _assets);
            return;
        }

        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        EnumerableSet.UintSet storage ids = $.controllerRequests[_controller];
        uint256 n = ids.length();
        uint256[] memory list = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = ids.at(i);
        }
        _sortIds(list);

        uint256 remaining = _shares;
        uint256 remainingUnlocked = unlockedSupply();
        for (uint256 i; i < n && remaining > 0 && remainingUnlocked > 0; ++i) {
            uint256 claimable = _claimableShares(list[i], _controller);
            if (claimable > remainingUnlocked) claimable = remainingUnlocked;
            if (claimable == 0) continue;
            uint256 take = remaining < claimable ? remaining : claimable;
            _consumeRequest(_controller, take, list[i]);
            remaining -= take;
            remainingUnlocked -= take;
        }
        if (remaining != 0) revert IncompleteClaim(_shares - remaining, _shares);

        _payout(_receiver, _controller, _assets, _shares);
    }

    /// @dev Insertion-sort request ids so the oldest (lowest id) is claimed first.
    /// @param ids The request ids
    function _sortIds(uint256[] memory ids) private pure {
        uint256 n = ids.length;
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = ids[i];
            uint256 j = i;
            while (j > 0 && ids[j - 1] > key) {
                ids[j] = ids[j - 1];
                unchecked {
                    --j;
                }
            }
            ids[j] = key;
        }
    }

    /// @dev Settle a queued claim. Caller authorization is the caller's responsibility.
    /// @param _receiver The receiver of the assets
    /// @param _controller The controller of the request
    /// @param _assets The number of assets to withdraw
    /// @param _shares The number of shares to withdraw
    /// @param _requestId The id of the request
    function _claim(address _receiver, address _controller, uint256 _assets, uint256 _shares, uint256 _requestId)
        internal
    {
        uint256 unlocked = unlockedSupply();
        if (_shares > unlocked) revert ERC4626ExceededMaxRedeem(_controller, _shares, unlocked);

        _consumeRequest(_controller, _shares, _requestId);
        _payout(_receiver, _controller, _assets, _shares);
    }

    /// @dev Take `_shares` off a request and burn them. Does not pay assets.
    /// Emits {RedeemRequestConsumed} so individual and FIFO claims both name the receipt.
    /// @param _controller The request controller
    /// @param _shares The shares to consume
    /// @param _requestId The request id
    function _consumeRequest(address _controller, uint256 _shares, uint256 _requestId) internal {
        ERC7540AsyncRedeemStorage storage $ = _getERC7540AsyncRedeemStorage();
        $.queueIndex[_requestId] += _shares;
        uint256 remaining = $.requestShares[_requestId] - _shares;
        $.requestShares[_requestId] = remaining;
        if (remaining == 0) {
            delete $.requestController[_requestId];
            $.controllerRequests[_controller].remove(_requestId);
        }

        _burn(address(this), _shares);
        $.settledQueue += _shares;
        emit RedeemRequestConsumed(_requestId, _controller, _shares, remaining);
    }

    /// @dev Pay `_assets` once for a completed consume of `_shares`.
    /// @param _receiver The asset recipient
    /// @param _controller The request controller
    /// @param _assets The assets to pay
    /// @param _shares The shares that were burned
    function _payout(address _receiver, address _controller, uint256 _assets, uint256 _shares) internal {
        _onWithdraw(_controller, _assets, _shares);
        _transferOut(_receiver, _assets);
        emit Withdraw(msg.sender, _receiver, _controller, _assets, _shares);
    }

    /// @dev Instant withdraw. Allowance may stand in for the owner.
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

    /// @dev Shared hook after the burn, before {_transferOut}. Instant and queued both land here.
    /// @param _owner The account whose shares were burned, or the controller of a queued request
    /// @param _assets The number of assets being paid out
    /// @param _shares The number of shares burned
    function _onWithdraw(address _owner, uint256 _assets, uint256 _shares) internal virtual { }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IERC4626).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540AsyncRedeem).interfaceId
            || interfaceId == type(IERC7575).interfaceId || super.supportsInterface(interfaceId);
    }
}
