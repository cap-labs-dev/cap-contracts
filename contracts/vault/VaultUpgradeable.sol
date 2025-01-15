// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";
import { MinterUpgradeable } from "./MinterUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title Vault for storing the backing for cTokens
/// @author kexley, @capLabs
/// @notice Tokens are supplied by cToken minters and borrowed by covered agents
/// @dev Supplies, borrows and utilization rates are tracked. Interest rates should be computed and
/// charged on the external contracts, only the principle amount is counted on this contract.
contract VaultUpgradeable is ERC20PermitUpgradeable, AccessUpgradeable, MinterUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:cap.storage.Vault
    struct VaultStorage {
        address[] assets;
        mapping(address => uint256) totalSupplies;
        mapping(address => uint256) totalBorrows;
        mapping(address => uint256) utilizationIndex;
        mapping(address => uint256) lastUpdate;
        mapping(address => bool) paused;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultStorageLocation = 0xe912a1b0cc7579bc5827e495c2ce52587bc3871751e3281fc5599b38c3bfc400;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getVaultStorage() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VaultStorageLocation
        }
    }

    /// @dev Initialize the assets
    /// @param _name Name of the cap token
    /// @param _symbol Symbol of the cap token
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _assets Asset addresses
    function __Vault_init(
        string memory _name,
        string memory _symbol,
        address _accessControl,
        address _oracle,
        address[] calldata _assets
    ) internal onlyInitializing {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Access_init(_accessControl);
        __Minter_init_unchained(_oracle);
        __Vault_init_unchained(_assets);
    }

    /// @dev Initialize unchained
    /// @param _assets Asset addresses
    function __Vault_init_unchained(address[] calldata _assets) internal onlyInitializing {
        VaultStorage storage $ = _getVaultStorage();
        $.assets = _assets;
    }

    /// @dev Timestamp is past the deadline
    error PastDeadline();

    /// @dev Amount out is less than required
    error Slippage(address asset, uint256 amountOut, uint256 minAmountOut);

    /// @dev Paused assets cannot be supplied or borrowed
    error AssetPaused(address asset);

    /// @dev Only whitelisted assets can be supplied or borrowed
    error AssetNotSupported(address asset);

    /// @dev Asset is already listed
    error AssetAlreadySupported(address asset);

    /// @dev Only non-supported assets can be rescued
    error AssetNotRescuable(address asset);

    /// @dev Cap token minted
    event Mint(address indexed minter, address receiver, address indexed asset, uint256 amountIn, uint256 amountOut);

    /// @dev Cap token burned
    event Burn(address indexed burner, address receiver, address indexed asset, uint256 amountIn, uint256 amountOut);

    /// @dev Cap token redeemed
    event Redeem(address indexed redeemer, address receiver, uint256 amountIn, uint256[] amountsOut);

    /// @dev Borrow made
    event Borrow(address indexed borrower, address indexed asset, uint256 amount);

    /// @dev Repayment made
    event Repay(address indexed repayer, address indexed asset, uint256 amount);

    /// @dev Asset paused
    event PauseAsset(address asset);

    /// @dev Asset unpaused
    event UnpauseAsset(address asset);

    /// @dev Modifier to only allow supplies and borrows when not paused
    /// @param _asset Asset address
    modifier whenNotPaused(address _asset) {
        _whenNotPaused(_asset);
        _;
    }

    /// @dev Modifier to update the utilization index
    /// @param _asset Asset address
    modifier updateIndex(address _asset) {
        _updateIndex(_asset);
        _;
    }

    /// @notice Mint the cap token using an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amountIn Amount of asset to use in the minting
    /// @param _minAmountOut Minimum amount to mint
    /// @param _receiver Receiver of the minting
    /// @param _deadline Deadline of the tx
    function mint(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    )
        external
        whenNotPaused(_asset)
        updateIndex(_asset)
        returns (uint256 amountOut)
    {
        if (_deadline < block.timestamp) revert PastDeadline();
        amountOut = getMintAmount(_asset, _amountIn);
        if (amountOut < _minAmountOut) revert Slippage(address(this), amountOut, _minAmountOut);

        VaultStorage storage $ = _getVaultStorage();
        $.totalSupplies[_asset] += _amountIn;

        _mint(_receiver, amountOut);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amountIn);

        emit Mint(msg.sender, _receiver, _asset, _amountIn, amountOut);
    }

    /// @notice Burn the cap token for an asset
    /// @dev Can only withdraw up to the amount remaining on this contract
    /// @param _asset Asset to withdraw
    /// @param _amountIn Amount of cap token to burn
    /// @param _minAmountOut Minimum amount out to receive
    /// @param _receiver Receiver of the withdrawal
    /// @param _deadline Deadline of the tx
    function burn(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    )
        external
        updateIndex(_asset)
        returns (uint256 amountOut)
    {
        if (_deadline < block.timestamp) revert PastDeadline();
        amountOut = getBurnAmount(_asset, _amountIn);
        if (amountOut < _minAmountOut) revert Slippage(_asset, amountOut, _minAmountOut);

        VaultStorage storage $ = _getVaultStorage();
        $.totalSupplies[_asset] -= amountOut;

        _burn(msg.sender, _amountIn);
        IERC20(_asset).safeTransfer(_receiver, amountOut);

        emit Burn(msg.sender, _receiver, _asset, _amountIn, amountOut);
    }

    /// @notice Redeem the Cap token for a bundle of assets
    /// @dev Can only withdraw up to the amount remaining on this contract
    /// @param _amountIn Amount of Cap token to burn
    /// @param _minAmountsOut Minimum amounts of assets to withdraw
    /// @param _receiver Receiver of the withdrawal
    /// @param _deadline Deadline of the tx
    /// @return amountsOut Amount of assets withdrawn
    function redeem(
        uint256 _amountIn,
        uint256[] calldata _minAmountsOut,
        address _receiver,
        uint256 _deadline
    )
        external
        returns (uint256[] memory amountsOut)
    {
        if (_deadline < block.timestamp) revert PastDeadline();
        amountsOut = getRedeemAmount(_amountIn);

        _burn(msg.sender, _amountIn);

        VaultStorage storage $ = _getVaultStorage();
        address[] memory cachedAssets = $.assets;
        for (uint256 i; i < cachedAssets.length; ++i) {
            if (amountsOut[i] < _minAmountsOut[i]) revert Slippage(cachedAssets[i], amountsOut[i], _minAmountsOut[i]);
            _updateIndex(cachedAssets[i]);
            $.totalSupplies[cachedAssets[i]] -= amountsOut[i];
            IERC20(cachedAssets[i]).safeTransfer(_receiver, amountsOut[i]);
        }

        emit Redeem(msg.sender, _receiver, _amountIn, amountsOut);
    }

    /// @notice Borrow an asset
    /// @dev Whitelisted agents can borrow any amount, LTV is handled by Agent contracts
    /// @param _asset Asset to borrow
    /// @param _amount Amount of asset to borrow
    /// @param _receiver Receiver of the borrow
    function borrow(address _asset, uint256 _amount, address _receiver)
        external
        whenNotPaused(_asset)
        updateIndex(_asset)
        checkAccess(this.borrow.selector)
    {
        VaultStorage storage $ = _getVaultStorage();
        $.totalBorrows[_asset] += _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);

        emit Borrow(msg.sender, _asset, _amount);
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay
    function repay(address _asset, uint256 _amount)
        external
        updateIndex(_asset)
        checkAccess(this.repay.selector)
    {
        VaultStorage storage $ = _getVaultStorage();
        $.totalBorrows[_asset] -= _amount;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        emit Repay(msg.sender, _asset, _amount);
    }

    /// @notice Add an asset to the vault list
    /// @param _asset Asset address
    function addAsset(address _asset) external checkAccess(this.addAsset.selector) {
        if (listed(_asset)) revert AssetAlreadySupported(_asset);
        
        VaultStorage storage $ = _getVaultStorage();
        $.assets.push(_asset);
    }

    /// @notice Remove an asset from the vault list
    /// @param _asset Asset address
    function removeAsset(address _asset) external checkAccess(this.removeAsset.selector) {
        VaultStorage storage $ = _getVaultStorage();
        address[] memory cachedAssets = $.assets;
        uint256 length = cachedAssets.length;
        bool removed;
        for (uint256 i; i < length; ++i) {
            if (_asset == cachedAssets[i]) {
                $.assets[i] = cachedAssets[length - 1];
                $.assets.pop();
                removed = true;
                break;
            }
        }

        if (!removed) revert AssetNotSupported(_asset);
    }

    /// @notice Pause an asset
    /// @param _asset Asset address
    function pause(address _asset) external checkAccess(this.pause.selector) {
        VaultStorage storage $ = _getVaultStorage();
        $.paused[_asset] = true;
        emit PauseAsset(_asset);
    }

    /// @notice Unpause an asset
    /// @param _asset Asset address
    function unpause(address _asset) external checkAccess(this.unpause.selector) {
        VaultStorage storage $ = _getVaultStorage();
        $.paused[_asset] = false;
        emit UnpauseAsset(_asset);
    }

    /// @notice Rescue an unsupported asset
    /// @param _asset Asset to rescue
    /// @param _receiver Receiver of the rescue
    function rescueERC20(address _asset, address _receiver) external checkAccess(this.rescueERC20.selector) {
        if (listed(_asset)) revert AssetNotRescuable(_asset);
        IERC20(_asset).safeTransfer(_receiver, IERC20(_asset).balanceOf(address(this)));
    }

    /// @notice Get the list of assets supported by the vault
    /// @return assetList List of assets
    function assets() external view returns (address[] memory assetList) {
        VaultStorage storage $ = _getVaultStorage();
        assetList = $.assets;
    }

    /// @notice Get the total supplies of an asset
    /// @param _asset Asset address
    /// @return totalSupply Total supply
    function totalSupplies(address _asset) external view returns (uint256 totalSupply) {
        VaultStorage storage $ = _getVaultStorage();
        totalSupply = $.totalSupplies[_asset];
    }

    /// @notice Get the total borrows of an asset
    /// @param _asset Asset address
    /// @return totalBorrow Total borrow
    function totalBorrows(address _asset) external view returns (uint256 totalBorrow) {
        VaultStorage storage $ = _getVaultStorage();
        totalBorrow = $.totalBorrows[_asset];
    }

    /// @notice Get the pause state of an asset
    /// @param _asset Asset address
    /// @return isPaused Pause state
    function paused(address _asset) external view returns (bool isPaused) {
        VaultStorage storage $ = _getVaultStorage();
        isPaused = $.paused[_asset];
    }

    /// @notice Validate that an asset is listed
    /// @param _asset Asset to check
    /// @return isListed Asset is listed or not
    function listed(address _asset) public view returns (bool isListed) {
        VaultStorage storage $ = _getVaultStorage();
        address[] memory cachedAssets = $.assets;
        uint256 length = cachedAssets.length;
        for (uint256 i; i < length; ++i) {
            if (_asset == cachedAssets[i]) {
                isListed = true;
                break;
            }
        }
    }

    /// @notice Available balance to borrow
    /// @param _asset Asset to borrow
    /// @return amount Amount available
    function availableBalance(address _asset) external view returns (uint256 amount) {
        VaultStorage storage $ = _getVaultStorage();
        amount = $.totalSupplies[_asset] - $.totalBorrows[_asset];
    }

    /// @notice Utilization rate of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return ratio Utilization ratio
    function utilization(address _asset) public view returns (uint256 ratio) {
        VaultStorage storage $ = _getVaultStorage();
        ratio = $.totalSupplies[_asset] != 0 ? $.totalBorrows[_asset] * 1e27 / $.totalSupplies[_asset] : 0;
    }

    /// @notice Up to date cumulative utilization index of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return index Utilization ratio index
    function currentUtilizationIndex(address _asset) external view returns (uint256 index) {
        VaultStorage storage $ = _getVaultStorage();
        index = $.utilizationIndex[_asset] + (utilization(_asset) * (block.timestamp - $.lastUpdate[_asset]));
    }

    /// @dev Only allow supplies and borrows when not paused
    /// @param _asset Asset address
    function _whenNotPaused(address _asset) private view {
        VaultStorage storage $ = _getVaultStorage();
        if ($.paused[_asset]) revert AssetPaused(_asset);
    }

    /// @dev Update the cumulative utilization index of an asset
    /// @param _asset Utilized asset
    function _updateIndex(address _asset) internal {
        if (!listed(_asset)) revert AssetNotSupported(_asset);

        VaultStorage storage $ = _getVaultStorage();
        $.utilizationIndex[_asset] += utilization(_asset) * (block.timestamp - $.lastUpdate[_asset]);
        $.lastUpdate[_asset] = block.timestamp;
    }
}
