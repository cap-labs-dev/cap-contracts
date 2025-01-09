// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultDataProvider {
    struct VaultData {
        address[] assets;
        uint256 redeemFee;
        bool paused;
    }

    struct AllocationData {
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    function VAULT_DATA_ADMIN() external view returns (bytes32);

    function vault(address capToken) external view returns (address);
    function vaultData(address vault) external view returns (VaultData memory);
    function allocationData(address vault) external view returns (AllocationData memory);
    function initialize(address _addressProvider) external;
    function createVault(
        address _capToken,
        VaultData calldata _vaultData,
        AllocationData[] calldata _allocationData
    ) external;
    function addAssetToVault(address _vault, address _asset, AllocationData calldata _allocationData) external;
    function removeAssetFromVault(address _vault, address _asset) external;
    function setAllocationData(address _vault, address _asset, AllocationData calldata _allocationData) external;
    function setPause(address _vault, bool _pause) external;
    function setRedeemFee(address _vault, uint256 _redeemFee) external;
    function assetSupported(address _vault, address _asset) external view returns (bool supported);
    function paused(address _vault) external view returns (bool pause);
}
