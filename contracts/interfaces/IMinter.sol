// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IMinter
/// @author kexley, Cap Labs
/// @notice Interface for Minter contract
interface IMinter {
    /// @dev Minter storage
    /// @param oracle Oracle address
    /// @param redeemFee Redeem fee
    /// @param fees Fees for each asset
    /// @param whitelist Whitelist for users
    struct MinterStorage {
        address oracle;
        uint256 redeemFee;
        mapping(address => FeeData) fees;
        mapping(address => bool) whitelist;
    }

    /// @dev Fee data set for an asset in a vault
    /// @param minMintFee Minimum mint fee
    /// @param slope0 Slope 0
    /// @param slope1 Slope 1
    /// @param mintKinkRatio Mint kink ratio
    /// @param burnKinkRatio Burn kink ratio
    /// @param optimalRatio Optimal ratio
    struct FeeData {
        uint256 minMintFee;
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    /// @dev Parameters for applying fee slopes
    /// @param mint True if applying to mint, false if applying to burn
    /// @param amount Amount of asset to apply fee to
    /// @param ratio Ratio of fee to apply
    struct FeeSlopeParams {
        bool mint;
        uint256 amount;
        uint256 ratio;
    }

    /// @dev Parameters for minting or burning
    /// @param mint True if minting, false if burning
    /// @param asset Asset address
    /// @param amount Amount of asset to mint or burn
    struct AmountOutParams {
        bool mint;
        address asset;
        uint256 amount;
    }

    /// @dev Parameters for redeeming
    /// @param amount Amount of cap token to redeem
    struct RedeemAmountOutParams {
        uint256 amount;
    }

    /// @dev Fee data set for an asset in a vault
    event SetFeeData(address asset, FeeData feeData);

    /// @dev Redeem fee set
    event SetRedeemFee(uint256 redeemFee);

    /// @dev Whitelist set
    event SetWhitelist(address user, bool whitelisted);

    /// @dev Invalid minimum mint fee
    error InvalidMinMintFee();

    /// @dev Invalid mint kink ratio
    error InvalidMintKinkRatio();

    /// @dev Invalid burn kink ratio
    error InvalidBurnKinkRatio();

    /// @dev Invalid optimal ratio
    error InvalidOptimalRatio();

    /// @notice Get the fee data for an asset
    /// @param _asset Asset address
    /// @return feeData Fee data for the asset
    function getFeeData(address _asset) external view returns (FeeData memory feeData);

    /// @notice Set the allocation slopes and ratios for an asset
    /// @param _asset Asset address
    /// @param _feeData Fee slopes and ratios for the asset in the vault
    function setFeeData(address _asset, FeeData calldata _feeData) external;

    /// @notice Get the redeem fee
    /// @return redeemFee Redeem fee amount
    function getRedeemFee() external view returns (uint256 redeemFee);

    /// @notice Set the redeem fee
    /// @param _redeemFee Redeem fee amount
    function setRedeemFee(uint256 _redeemFee) external;

    /// @notice Set the whitelist for a user
    /// @param _user User address
    /// @param _whitelisted Whitelist state
    function setWhitelist(address _user, bool _whitelisted) external;

    /// @notice Get the mint amount for a given asset
    /// @param _asset Asset address
    /// @param _amountIn Amount of asset to use
    /// @return amountOut Amount minted
    /// @return fee Fee applied
    function getMintAmount(address _asset, uint256 _amountIn) external view returns (uint256 amountOut, uint256 fee);

    /// @notice Estimate the mint amount in for a given asset
    /// @param _asset Asset address
    /// @param _amountOut Amount of cap token to mint
    /// @return amountIn Amount of asset to use
    function getMintAmountIn(address _asset, uint256 _amountOut) external view returns (uint256 amountIn);

    /// @notice Get the burn amount for a given asset
    /// @param _asset Asset address to withdraw
    /// @param _amountIn Amount of cap token to burn
    /// @return amountOut Amount of the asset withdrawn
    /// @return fee Fee applied
    function getBurnAmount(address _asset, uint256 _amountIn) external view returns (uint256 amountOut, uint256 fee);

    /// @notice Estimate the burn amount in for a given asset
    /// @param _asset Asset address
    /// @param _amountOut Amount of cap token to burn
    /// @return amountIn Amount of asset to use
    function getBurnAmountIn(address _asset, uint256 _amountOut) external view returns (uint256 amountIn);

    /// @notice Get the redeem amount
    /// @param _amountIn Amount of cap token to burn
    /// @return amountsOut Amounts of assets to be withdrawn
    /// @return redeemFees Amounts of redeem fees to be applied
    function getRedeemAmount(uint256 _amountIn)
        external
        view
        returns (uint256[] memory amountsOut, uint256[] memory redeemFees);

    /// @notice Is user whitelisted
    /// @param _user User address
    /// @return isWhitelisted Whitelist state
    function whitelisted(address _user) external view returns (bool isWhitelisted);
}
