// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";

/// @title Vault for storing the backing for cTokens
/// @author kexley, @capLabs
/// @notice Tokens are supplied by cToken minters and borrowed by covered agents
/// @dev Supplies, borrows and utilization rates are tracked. Interest rates should be computed and
/// charged on the external contracts, only the principle amount is counted on this contract.
contract Vault is UUPSUpgradeable, AccessUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Assets supported by the vault
    address[] public _assets;

    /// @notice Total supply of an asset to this contract
    mapping(address => uint256) public totalSupplies;

    /// @notice Total borrows of an asset from this contract
    mapping(address => uint256) public totalBorrows;

    /// @notice Cumulative utilization index of an asset
    mapping(address => uint256) public utilizationIndex;

    /// @notice Timestamp of the last update to the utilization index
    mapping(address => uint256) public lastUpdate;

    /// @notice Asset pause state
    mapping(address => bool) public paused;

    /// @dev No transfer tokens allowed
    error TransferTaxNotSupported();

    /// @dev Paused assets cannot be supplied or borrowed
    error AssetPaused(address asset);

    /// @dev Only whitelisted assets can be supplied or borrowed
    error AssetNotSupported(address asset);

    /// @dev Asset is already listed
    error AssetAlreadySupported(address asset);

    /// @dev Only non-supported assets can be rescued
    error AssetNotRescuable(address asset);

    /// @dev Deposit made
    event Deposit(address indexed depositor, address indexed asset, uint256 amount);

    /// @dev Withdrawal made
    event Withdraw(address indexed withrawer, address indexed asset, uint256 amount);

    /// @dev Borrow made
    event Borrow(address indexed borrower, address indexed asset, uint256 amount);

    /// @dev Repayment made
    event Repay(address indexed repayer, address indexed asset, uint256 amount);

    /// @dev Asset paused
    event PauseAsset(address asset);

    /// @dev Asset unpaused
    event UnpauseAsset(address asset);

    /// @dev Only allow supplies and borrows when not paused
    /// @param _asset Asset address
    modifier whenNotPaused(address _asset) {
        if (paused[_asset]) revert AssetPaused(_asset);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault with the access control
    /// @param _accessControl Access control address
    function initialize(address _accessControl) external initializer {
        __Access_init(_accessControl);
    }

    /// @notice Get the list of assets supported by the vault
    /// @return assets List of assets
    function assets() external view returns (address[] memory assets) {
        return _assets;
    }

    /// @notice Deposit an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amount Amount of asset to deposit
    function deposit(address _asset, uint256 _amount)
        external
        whenNotPaused(_asset)
        checkAccess(this.deposit.selector)
    {
        if (!listed(_asset)) revert AssetNotSupported(_asset);
        _updateIndex(_asset);

        totalSupplies[_asset] += _amount;
        uint256 beforeBalance = IERC20(_asset).balanceOf(address(this));
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBalance = IERC20(_asset).balanceOf(address(this));
        if (afterBalance != beforeBalance + _amount) revert TransferTaxNotSupported();

        emit Deposit(msg.sender, _asset, _amount);
    }

    /// @notice Withdraw an asset
    /// @dev Can only withdraw up to the amount remaining on this contract
    /// @param _asset Asset to withdraw
    /// @param _amount Amount of asset to withdraw
    /// @param _receiver Receiver of the withdrawal
    function withdraw(address _asset, uint256 _amount, address _receiver)
        external
        checkAccess(this.withdraw.selector)
    {
        if (!listed(_asset)) revert AssetNotSupported(_asset);
        _updateIndex(_asset);

        totalSupplies[_asset] -= _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);

        emit Withdraw(msg.sender, _asset, _amount);
    }

    /// @notice Borrow an asset
    /// @dev Whitelisted agents can borrow any amount, LTV is handled by Agent contracts
    /// @param _asset Asset to borrow
    /// @param _amount Amount of asset to borrow
    /// @param _receiver Receiver of the borrow
    function borrow(address _asset, uint256 _amount, address _receiver)
        external
        whenNotPaused(_asset)
        checkAccess(this.borrow.selector)
    {
        if (!listed(_asset)) revert AssetNotSupported(_asset);
        _updateIndex(_asset);

        totalBorrows[_asset] += _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);

        emit Borrow(msg.sender, _asset, _amount);
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay
    function repay(address _asset, uint256 _amount) external checkAccess(this.repay.selector) {
        if (!listed(_asset)) revert AssetNotSupported(_asset);
        _updateIndex(_asset);

        totalBorrows[_asset] -= _amount;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        emit Repay(msg.sender, _asset, _amount);
    }

    /// @notice Add an asset to the vault list
    /// @param _asset Asset address
    function addAsset(address _asset) external checkAccess(this.addAsset.selector) {
        if (listed(_asset)) revert AssetAlreadySupported(_asset);
        _assets.push(_asset);
    }

    /// @notice Remove an asset from the vault list
    /// @param _asset Asset address
    function removeAsset(address _asset) external checkAccess(this.removeAsset.selector) {
        address[] memory cachedAssets = _assets;
        uint256 length = cachedAssets.length;
        bool removed;
        for (uint256 i; i < length; ++i) {
            if (_asset == cachedAssets[i]) {
                _assets[i] = cachedAssets[length - 1];
                _assets.pop();
                removed = true;
                break;
            }
        }

        if (!removed) revert AssetNotSupported(_asset);
    }

    /// @notice Pause an asset
    /// @param _asset Asset address
    function pause(address _asset) external checkAccess(this.pause.selector) {
        paused[_asset] = true;
        emit PauseAsset(_asset);
    }

    /// @notice Unpause an asset
    /// @param _asset Asset address
    function unpause(address _asset) external checkAccess(this.unpause.selector) {
        paused[_asset] = false;
        emit UnpauseAsset(_asset);
    }

    /// @notice Rescue an unsupported asset
    /// @param _asset Asset to rescue
    /// @param _receiver Receiver of the rescue
    function rescueERC20(address _asset, address _receiver) external checkAccess(this.rescueERC20.selector) {
        if (listed(_asset)) revert AssetNotRescuable(_asset);
        IERC20(_asset).safeTransfer(_receiver, IERC20(_asset).balanceOf(address(this)));
    }

    /// @dev Validate that an asset is listed
    /// @param _asset Asset to check
    /// @return isListed Asset is listed or not
    function listed(address _asset) public view returns (bool isListed) {
        address[] memory cachedAssets = _assets;
        uint256 length = _assets.length;
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
        amount = totalSupplies[_asset] - totalBorrows[_asset];
    }

    /// @notice Utilization rate of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return ratio Utilization ratio
    function utilization(address _asset) public view returns (uint256 ratio) {
        ratio = totalSupplies[_asset] != 0 ? totalBorrows[_asset] * 1e27 / totalSupplies[_asset] : 0;
    }

    /// @notice Up to date cumulative utilization index of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return index Utilization ratio index
    function currentUtilizationIndex(address _asset) external view returns (uint256 index) {
        index = utilizationIndex[_asset] + (utilization(_asset) * (block.timestamp - lastUpdate[_asset]));
    }

    /// @dev Update the cumulative utilization index of an asset
    /// @param _asset Utilized asset
    function _updateIndex(address _asset) internal {
        utilizationIndex[_asset] += utilization(_asset) * (block.timestamp - lastUpdate[_asset]);
        lastUpdate[_asset] = block.timestamp;
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
