// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CloneLogic} from "../lendingPool/libraries/CloneLogic.sol";
import {IAddressProvider} from "../interfaces/IAddressProvider.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IVaultDataProvider} from "../interfaces/IVaultDataProvider.sol";

/// @title VaultDataProvider
/// @notice Data provider for Cap token vaults
contract VaultDataProvider is IVaultDataProvider, UUPSUpgradeable {
    /// @notice Vault data admin role
    bytes32 public constant VAULT_DATA_ADMIN = keccak256("VAULT_DATA_ADMIN");

    /// @notice Vault keeper role
    bytes32 public constant VAULT_DATA_KEEPER = keccak256("VAULT_DATA_KEEPER");

    /// @notice Address provider
    IAddressProvider public addressProvider;

    mapping(address => address) public vaultByCapToken;
    mapping(address => VaultData) public vaultDataByVault;
    mapping(address => mapping(address => AllocationData)) public allocationDataByVaultAndAsset;

    error VaultAlreadyExists();
    error AssetAlreadyListed();

    event CreateVault(address capToken, address vault, VaultData vaultData);
    event AddAssetToVault(address vault, address asset);
    event RemoveAssetFromVault(address vault, address asset);
    event SetAllocationData(address vault, address asset, AllocationData allocationDataByVaultAndAsset);
    event SetPause(address vault, bool paused);
    event SetRedeemFee(address vault, uint256 redeemFee);

    /// @dev Only admin are allowed to call functions
    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    /// @dev Reverts if the caller is not admin
    function _onlyAdmin() private view {
        addressProvider.checkRole(VAULT_DATA_ADMIN, msg.sender);
    }

    /// @dev Only keeper are allowed to call functions
    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    /// @dev Reverts if the caller is not keeper
    function _onlyKeeper() private view {
        addressProvider.checkRole(VAULT_DATA_KEEPER, msg.sender);
    }

    /// @notice Initialize the address provider
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
    }

    /// @notice Get vault address for a cap token
    /// @param _capToken Cap token address
    /// @return vault Vault address
    function vault(address _capToken) external view returns (address) {
        return vaultByCapToken[_capToken];
    }

    /// @notice Get vault data for a vault
    /// @param _vault Vault address
    /// @return VaultData struct containing assets, redeem fee and pause state
    function vaultData(address _vault) external view returns (VaultData memory) {
        return vaultDataByVault[_vault];
    }

    /// @notice Get allocation data for a vault and asset
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @return AllocationData struct containing slopes and ratios
    function allocationData(address _vault, address _asset) external view returns (AllocationData memory) {
        return allocationDataByVaultAndAsset[_vault][_asset];
    }

    /// @notice Check if an asset is supported by a vault
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @return supported True if asset is supported
    function assetSupported(address _vault, address _asset) external view returns (bool supported) {
        VaultData memory data = vaultDataByVault[_vault];
        uint256 length = data.assets.length;
        for (uint256 i; i < length; ++i) {
            if (data.assets[i] == _asset) {
                return true;
            }
        }
        return false;
    }

    /// @notice Check if a vault is paused
    /// @param _vault Vault address
    /// @return pause True if vault is paused
    function paused(address _vault) external view returns (bool) {
        return vaultDataByVault[_vault].paused;
    }

    /// @notice Create a vault for a Cap token
    /// @param _capToken Cap token address
    /// @param _vaultData Initial assets, redeem fee and pause state for the vault
    /// @param _allocationData Allocation slopes and ratios
    /// @return newVault Created vault
    function createVault(address _capToken, VaultData calldata _vaultData, AllocationData[] memory _allocationData)
        external
        onlyAdmin
        returns (address newVault)
    {
        if (vaultByCapToken[_capToken] != address(0)) revert VaultAlreadyExists();

        newVault = CloneLogic.clone(addressProvider.vaultInstance());
        IVault(newVault).initialize(address(addressProvider));

        vaultByCapToken[_capToken] = newVault;
        vaultDataByVault[newVault] = _vaultData;

        uint256 length = _vaultData.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = _vaultData.assets[i];
            allocationDataByVaultAndAsset[newVault][asset] = _allocationData[i];
        }

        emit CreateVault(_capToken, newVault, _vaultData);
    }

    /// @notice Add an asset to a vault
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @param _allocationData Allocation slopes and ratios for the asset
    function addAssetToVault(address _vault, address _asset, AllocationData calldata _allocationData)
        external
        onlyAdmin
    {
        VaultData storage data = vaultDataByVault[_vault];

        uint256 length = data.assets.length;
        for (uint256 i; i < length; ++i) {
            if (data.assets[i] == _asset) revert AssetAlreadyListed();
        }

        data.assets.push(_asset);
        emit AddAssetToVault(_vault, _asset);

        allocationDataByVaultAndAsset[_vault][_asset] = _allocationData;
        emit SetAllocationData(_vault, _asset, _allocationData);
    }

    /// @notice Remove an asset from a vault
    /// @dev Once removed the asset cannot be interacted with on the vault, only rescued
    /// @param _vault Vault address
    /// @param _asset Asset address
    function removeAssetFromVault(address _vault, address _asset) external onlyAdmin {
        VaultData storage data = vaultDataByVault[_vault];

        uint256 length = data.assets.length;
        for (uint256 i; i < length; ++i) {
            if (data.assets[i] == _asset) {
                data.assets[i] = data.assets[length - 1];

                data.assets.pop();
                emit RemoveAssetFromVault(_vault, _asset);

                delete allocationDataByVaultAndAsset[_vault][_asset];
                emit SetAllocationData(_vault, _asset, allocationDataByVaultAndAsset[_vault][_asset]);
                break;
            }
        }
    }

    /// @notice Set the allocation slopes and ratios for an asset in a vault
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @param _allocationData Allocation slopes and ratios for the asset in the vault
    function setAllocationData(address _vault, address _asset, AllocationData calldata _allocationData)
        external
        onlyKeeper
    {
        allocationDataByVaultAndAsset[_vault][_asset] = _allocationData;
        emit SetAllocationData(_vault, _asset, _allocationData);
    }

    /// @notice Pause supplies and borrows on a vault, allow withdrawals and repayments
    /// @param _vault Vault address
    /// @param _pause Toggle pause state
    function setPause(address _vault, bool _pause) external onlyKeeper {
        vaultDataByVault[_vault].paused = _pause;
        emit SetPause(_vault, _pause);
    }

    /// @notice Set redeem fee for a vault
    /// @param _vault Vault address
    /// @param _redeemFee Redeem fee in 27 decimals
    function setRedeemFee(address _vault, uint256 _redeemFee) external onlyKeeper {
        vaultDataByVault[_vault].redeemFee = _redeemFee;
        emit SetRedeemFee(_vault, _redeemFee);
    }

    /// @dev Only admin can upgrade the contract
    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
