// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";

/// @title Vault for storing the backing for cTokens
/// @author kexley, @capLabs
/// @notice Tokens are supplied by cToken minters and borrowed by covered agents
/// @dev Supplies, borrows and utilization rates are tracked. Interest rates should be computed and
/// charged on the external contracts, only the principle amount is counted on this contract. Asset
/// whitelisting is handled via the registry.
contract Vault is Initializable, PausableUpgradeable {
    /// @notice Registry that controls whitelisting assets
    IRegistry public registry;

    /// @notice Total supply of an asset to this contract
    mapping(address => uint256) public totalSupplies;

    /// @notice Total borrows of an asset from this contract
    mapping(address => uint256) public totalBorrows;

    /// @notice Cumulative utilization index of an asset
    mapping(address => uint256) public utilizationIndex;

    /// @notice Timestamp of the last update to the utilization index
    mapping(address => uint256) public lastUpdate;

    /// @dev No transfer tokens allowed
    error TransferTaxNotSupported();

    /// @dev Only whitelisted assets can be supplied or borrowed
    error AssetNotSupported(address asset);

    /// @dev Deposit made
    event Deposit(address indexed depositor, address indexed asset, uint256 amount);

    /// @dev Withdrawal made
    event Withdraw(address indexed withrawer, address indexed asset, uint256 amount);

    /// @dev Borrow made
    event Borrow(address indexed borrower, address indexed asset, uint256 amount);

    /// @dev Repayment made
    event Repay(address indexed repayer, address indexed asset, uint256 amount);

    /// @notice Initialize the registry address and default admin
    /// @param _registry Registry address
    function initialize(address _registry) initializer external {
        registry = IRegistry(_registry);
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Deposit an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amount Amount of asset to deposit
    function deposit(address _asset, uint256 _amount) external whenNotPaused onlyRole(SUPPLIER_ROLE) {
        _validate(_asset);
        _updateIndex(_asset);
        totalSupplies[_asset] += _amount;
        uint256 beforeBalance = IERC20(_asset).balanceOf(address(this));
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBalance = IERC20(_asset).balanceOf(address(this));
        if (afterBalance != beforeBalance + _amount) TransferTaxNotSupported();
        emit Deposit(msg.sender, _asset, _amount);
    }

    /// @notice Withdraw an asset
    /// @dev Can only withdraw up to the amount remaining on this contract
    /// @param _asset Asset to withdraw
    /// @param _amount Amount of asset to withdraw
    /// @param _receiver Receiver of the withdrawal
    function withdraw(address _asset, uint256 _amount, address _receiver) external onlyRole(SUPPLIER_ROLE) {
        _validate(_asset);
        _updateIndex(_asset);
        totalSupplies[_asset] -= _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);
        emit Withdraw(msg.sender, _asset, _amount);
    }

    /// @notice Borrow an asset
    /// @dev Whitelisted agents can borrow any amount, LTV is handled directly by Agent contracts
    /// @param _asset Asset to borrow
    /// @param _amount Amount of asset to borrow
    /// @param _receiver Receiver of the borrow
    function borrow(address _asset, uint256 _amount, address _receiver) external whenNotPaused onlyRole(BORROWER_ROLE) {
        _validate(_asset);
        _updateIndex(_asset);
        totalBorrows[_asset] += _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);
        emit Borrow(msg.sender, _asset, _amount);
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay
    function repay(address _asset, uint256 _amount) external onlyRole(BORROWER_ROLE) {
        _validate(_asset);
        _updateIndex(_asset);
        totalBorrows[_asset] -= _amount;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        emit Repay(msg.sender, _asset, _amount);
    }

    /// @notice Rescue an unsupported asset
    /// @param _asset Asset to rescue
    /// @param _receiver Receiver of the rescue
    function rescueERC20(address _asset, address _receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registry.supportedAssets(_asset)) revert AssetNotRescuable(_asset);
        IERC20(_asset).safeTransfer(_receiver, IERC20(_asset).balanceOf(address(this)));
    }

    /// @notice Pause vault
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause vault
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
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
        ratio = totalSupplies[_asset] != 0 
            ? totalBorrows[_asset] * 1e27 / totalSupplies[_asset]
            : 0;
    }

    /// @notice Up to date cumulative utilization index of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return index Utilization ratio index
    function currentUtilizationIndex(address _asset) external view returns (uint256 index) {
        index = utilizationIndex[_asset] + ( utilization(_asset) * ( block.timestamp - lastUpdate[_asset] ) );
    }

    /// @dev Update the cumulative utilization index of an asset
    /// @param _asset Utilized asset
    function _updateIndex(address _asset) internal {
        utilizationIndex[_asset] += utilization(_asset) * ( block.timestamp - lastUpdate[_asset] );
        lastUpdate[_asset] = block.timestamp;
    }

    /// @dev Validate that an asset is whitelisted
    /// @param _asset Asset to check
    function _validate(address _asset) internal {
        if (!registry.supportedAssets(_asset)) revert AssetNotSupported(_asset);
    }
}
