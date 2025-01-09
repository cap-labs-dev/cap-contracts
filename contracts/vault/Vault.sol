// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { IVaultDataProvider } from "../interfaces/IVaultDataProvider.sol";

/// @title Vault for storing the backing for cTokens
/// @author kexley, @capLabs
/// @notice Tokens are supplied by cToken minters and borrowed by covered agents
/// @dev Supplies, borrows and utilization rates are tracked. Interest rates should be computed and
/// charged on the external contracts, only the principle amount is counted on this contract. Asset
/// whitelisting is handled via the vault data provider.
contract Vault is UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Vault admin role
    bytes32 public constant VAULT_ADMIN = keccak256("VAULT_ADMIN");

    /// @notice Supplier role
    bytes32 public constant VAULT_SUPPLIER = keccak256("VAULT_SUPPLIER");

    /// @notice Borrower role
    bytes32 public constant VAULT_BORROWER = keccak256("VAULT_BORROWER");

    /// @notice Address provider
    IAddressProvider public addressProvider;

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

    /// @dev Only non-supported assets can be rescued
    error AssetNotRescuable(address asset);

    /// @dev Supplies and borrows are paused
    error Paused();

    /// @dev Deposit made
    event Deposit(address indexed depositor, address indexed asset, uint256 amount);

    /// @dev Withdrawal made
    event Withdraw(address indexed withrawer, address indexed asset, uint256 amount);

    /// @dev Borrow made
    event Borrow(address indexed borrower, address indexed asset, uint256 amount);

    /// @dev Repayment made
    event Repay(address indexed repayer, address indexed asset, uint256 amount);

    /// @dev Only admin are allowed to call functions
    modifier onlyAdmin {
        _onlyAdmin();
        _;
    }

    /// @dev Only suppliers are allowed to call functions
    modifier onlySupplier {
        _onlySupplier();
        _;
    }

    /// @dev Only borrowers are allowed to call functions
    modifier onlyBorrower {
        _onlyBorrower();
        _;
    }

    /// @dev Only allowed when not paused
    modifier whenNotPaused {
        _whenNotPaused();
        _;
    }

    /// @dev Reverts if the caller is not admin
    function _onlyAdmin() private view {
        addressProvider.checkRole(VAULT_ADMIN, msg.sender);
    }

    /// @dev Reverts if the caller is not supplier
    function _onlySupplier() private view {
        addressProvider.checkRole(VAULT_SUPPLIER, msg.sender);
    }

    /// @dev Reverts if the caller is not borrower
    function _onlyBorrower() private view {
        addressProvider.checkRole(VAULT_BORROWER, msg.sender);
    }

    /// @dev Reverts if the vault is not paused
    function _whenNotPaused() private view {
        IVaultDataProvider vaultDataProvider = IVaultDataProvider(addressProvider.vaultDataProvider());
        if (!vaultDataProvider.paused(address(this))) revert Paused();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the address provider address
    /// @param _addressProvider Address provider address
    function initialize(address _addressProvider) initializer external {
        addressProvider = IAddressProvider(_addressProvider);
    }

    /// @notice Deposit an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amount Amount of asset to deposit
    function deposit(address _asset, uint256 _amount) external whenNotPaused onlySupplier {
        _validate(_asset);
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
    function withdraw(address _asset, uint256 _amount, address _receiver) external onlySupplier {
        _validate(_asset);
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
    function borrow(address _asset, uint256 _amount, address _receiver) external whenNotPaused onlyBorrower {
        _validate(_asset);
        _updateIndex(_asset);
        totalBorrows[_asset] += _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);
        emit Borrow(msg.sender, _asset, _amount);
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay
    function repay(address _asset, uint256 _amount) external onlyBorrower {
        _validate(_asset);
        _updateIndex(_asset);
        totalBorrows[_asset] -= _amount;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        emit Repay(msg.sender, _asset, _amount);
    }

    /// @notice Rescue an unsupported asset
    /// @param _asset Asset to rescue
    /// @param _receiver Receiver of the rescue
    function rescueERC20(address _asset, address _receiver) external onlyAdmin {
        IVaultDataProvider vaultDataProvider = IVaultDataProvider(addressProvider.vaultDataProvider());
        if (vaultDataProvider.assetSupported(address(this), _asset)) revert AssetNotRescuable(_asset);

        IERC20(_asset).safeTransfer(_receiver, IERC20(_asset).balanceOf(address(this)));
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
    function _validate(address _asset) internal view {
        IVaultDataProvider vaultDataProvider = IVaultDataProvider(addressProvider.vaultDataProvider());
        if (!vaultDataProvider.assetSupported(address(this), _asset)) revert AssetNotSupported(_asset);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
