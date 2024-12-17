// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is Initializable, AccessControlEnumerableUpgradeable {

    struct Reserve {
        mapping(address => uint256) borrowed;
        mapping(address => uint256) accrued;
        mapping(address => uint256) storedBorrowIndex;
        uint256 borrowIndex;
        uint256 utilizationIndex;
        uint256 lastUpdate;
        uint256 ltv;
    }

    IRegistry public registry;

    mapping(address => Reserve) public reserve;

    address[] public assets;
    address[] public borrowers;
    mapping(address => bool) public supportedAssets;
    mapping(address => bool) public supportedBorrowers;
    mapping(address => uint256) public score;

    function initialize(address _registry) initializer external {
        registry = IRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Borrow an asset from a vault
    /// @param _vault Vault to borrow from
    /// @param _asset Asset to borrow from vault
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    function borrow(address _vault, address _asset, uint256 _amount, address _receiver) external {
        _validateAsset(_vault, _asset);
        _validateBorrow(msg.sender, _asset, _amount);
        _accrueInterest(_vault, _asset, msg.sender);
        reserve[_vault][_asset].borrowed[msg.sender] += _amount;
        reserve[_vault][_asset].benchmarkBorrowed[msg.sender] += _amount;
        IVault(_vault).borrow(_asset, _amount, _receiver);
        _updateRate(_vault, _asset);
    }

    /// @notice Repay an asset to a vault
    /// @param _vault Vault to repay
    /// @param _asset Asset to repay to vault
    /// @param _amount Amount to repay
    /// @param _onBehalfOf Repay on behalf of another borrower
    /// @return repaid Actual amount repaid
    function repay(
        address _vault,
        address _asset,
        uint256 _amount,
        address _onBehalfOf
    ) external returns (uint256 repaid) {
        if (_onBehalfOf == address(0)) _onBehalfOf = msg.sender;
        _validateAsset(_vault, _asset);
        _accrueInterest(_vault, _asset, _onBehalfOf);
        uint256 principal = reserve[_vault][_asset].borrowed[_onBehalfOf];
        uint256 interest = reserve[_vault][_asset].interest[_onBehalfOf];
        uint256 benchmark = reserve[_vault][_asset].benchmarkInterest[_onBehalfOf];

        repaid = _amount;

        /// Pay off interest, then principle, then benchmark yield
        if (repaid <= interest) {
            reserve[_vault][_asset].interest[_onBehalfOf] -= repaid;
            IERC20(_asset).safeTransferFrom(msg.sender, rewarder, repaid);
            emit InterestRepaid(_vault, _asset, _onBehalfOf, repaid, reserve[_vault][_asset].interest[_onBehalfOf]);
        } else {
            reserve[_vault][_asset].interest[_onBehalfOf] = 0;

            if (_amount <= principal + interest) {
                uint256 principlePaid = _amount - interest;
                reserve[_vault][_asset].borrowed[_onBehalfOf] -= principlePaid;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, interest);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principlePaid);
                IERC20(_asset).forceApprove(address(vault), principlePaid);
                IVault(_vault).repay(_asset, principlePaid);

                emit InterestRepaid(_vault, _asset, _onBehalfOf, interest, 0);
                emit PrincipalRepaid(_vault, _asset, _onBehalfOf, principlePaid, reserve[_vault][_asset].borrowed[_onBehalfOf]);
            } else {
                uint256 benchmarkPaid = _amount - principal - interest;
                if (benchmarkPaid > benchmark) {
                    benchmarkPaid = benchmark;
                    repaid = benchmark + principal + interest;
                }
                reserve[_vault][_asset].borrowed[_onBehalfOf] = 0;
                reserve[_vault][_asset].benchmarkInterest[_onBehalfOf] -= benchmarkPaid;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, benchmarkPaid + interest);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principal);
                IERC20(_asset).forceApprove(address(vault), principal);
                IVault(_vault).repay(_asset, principal);

                emit InterestRepaid(_vault, _asset, _onBehalfOf, interest, 0);
                emit PrincipalRepaid(_vault, _asset, _onBehalfOf, principle, 0);
                emit BenchmarkRepaid(_vault, _asset, _onBehalfOf, benchmarkPaid, reserve[_vault][_asset].benchmarkInterest[_onBehalfOf]);
            }
        }

        _updateRate(_vault, _asset);
    }

    /// @dev Accrue interest to a borrower's balance
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that has interest
    /// @param _borrower Borrower of the asset
    function _accrueInterest(address _vault, address _asset, address _borrower) internal {
        _updateIndexes(_vault, _asset);

        reserve[_vault][_asset].benchmarkInterest[_borrower] = accruedBenchmarkInterest(_vault, _asset, _borrower);
        reserve[_vault][_asset].storedBenchmarkIndex[_borrower] = reserve[_vault][_asset].benchmarkIndex;

        reserve[_vault][_asset].interest[_borrower] = accruedInterest(_vault, _asset, _borrower);
        reserve[_vault][_asset].storedBorrowIndex[_borrower] = reserve[_vault][_asset].borrowIndex;
    }

    /// @dev Update the borrow index of an asset
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that is borrowed
    function _updateIndexes(_vault, address _asset) internal {
        reserve[_vault][_asset].benchmarkIndex *= MathUtils.calculateCompoundedInterest(
            reserve[_vault][_asset].benchmarkRate,
            reserve[_vault][_asset].lastUpdate
        );
        reserve[_vault][_asset].borrowIndex *= MathUtils.calculateCompoundedInterest(
            reserve[_vault][_asset].rate,
            reserve[_vault][_asset].lastUpdate
        );
        reserve[_vault][_asset].lastUpdate = block.timestamp;
    }

    /// @notice Fetch the borrow rate based on utilization slopes
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset to borrow
    /// @return rate Borrow rate scaled to 1e27
    function borrowRate(address _vault, address _asset) public view returns (uint256 rate) {
        rate = BorrowLogic.borrowRate(
            registry,
            _vault,
            _asset,
            reserve[_vault][_asset].utilizationIndex,
            reserve[_vault][_asset].lastUpdate
        );
    }

    /// @notice Fetch the amount of interest a borrower has accrued
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that was borrowed
    /// @param _borrower Borrower of the asset
    /// @return interest Amount of interest accrued
    function accruedInterest(
        address _vault,
        address _asset,
        address _borrower
    ) public view returns (uint256 interest) {
        uint256 borrowIndex;
        if (reserve[_vault][_asset].lastUpdate == block.timestamp) {
            borrowIndex = reserve[_vault][_asset].borrowIndex;
        } else {
            borrowIndex = reserve[_vault][_asset].borrowIndex 
                * MathUtils.calculateCompoundedInterest(
                    reserve[_vault][_asset].rate, 
                    reserve[_vault][_asset].lastUpdate
                );
        }

        interest = reserve[_vault][_asset].interest[_borrower] + (
            (
                reserve[_vault][_asset].borrowed[_borrower] 
                + reserve[_vault][_asset].interest[_borrower] 
            ) * ( borrowIndex - reserve[_vault][_asset].storedBorrowIndex[_borrower] )
        );
    }

    /// @notice Fetch the amount of interest a borrower has accrued
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that was borrowed
    /// @param _borrower Borrower of the asset
    /// @return interest Amount of interest accrued
    function accruedBenchmarkInterest(
        address _vault,
        address _asset,
        address _borrower
    ) public view returns (uint256 benchmarkInterest) {
        uint256 benchmarkIndex;
        if (reserve[_vault][_asset].lastUpdate == block.timestamp) {
            benchmarkIndex = reserve[_vault][_asset].benchmarkIndex;
        } else {
            benchmarkIndex = reserve[_vault][_asset].benchmarkIndex 
                * MathUtils.calculateCompoundedInterest(
                    reserve[_vault][_asset].benchmarkRate, 
                    reserve[_vault][_asset].lastUpdate
                );
        }

        benchmarkInterest = reserve[_vault][_asset].benchmarkInterest[_borrower] + (
            (
                reserve[_vault][_asset].borrowed[_borrower] 
                + reserve[_vault][_asset].benchmarkInterest[_borrower]
            ) * ( benchmarkIndex - reserve[_vault][_asset].storedBenchmarkIndex[_borrower] )
        );
    }

    /// @notice Calculate amount borrowed by an agent including benchmark interest
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that was borrowed
    /// @param _borrower Borrower of the asset
    /// @return interest Amount of asset borrowed plus interest accrued
    function benchmarkBorrowed(
        address _vault,
        address _asset,
        address _borrower
    ) external view returns (uint256 borrowed) {
        borrowed = reserve[_vault][_asset].borrowed[_borrower] 
            + accruedBenchmarkInterest(_vault, _asset, _borrower);
    }

    /// @notice Calculate amount borrowed by an agent including interest
    /// @param _vault Vault that the asset was borrowed from
    /// @param _asset Asset that was borrowed
    /// @param _borrower Borrower of the asset
    /// @return interest Amount of asset borrowed plus interest accrued
    function borrowed(
        address _vault,
        address _asset,
        address _borrower
    ) external view returns (uint256 borrowed) {
        borrowed = reserve[_vault][_asset].borrowed[_borrower] 
            + accruedInterest(_vault, _asset, _borrower);
    }

    /// @notice Fetch the amount of asset that is available to borrow from a vault
    /// @param _vault Vault to borrow from
    /// @param _asset Asset to borrow from vault
    function availableBorrow(address _vault, address _asset) public view returns (uint256 available) {
        available = IVault(_vault).balance(_asset);
    }

    /* -------------------- VALIDATION -------------------- */

    function _validateAsset(address _vault, address _asset) internal {
        if (!registry.supportedAsset(_vault, _asset)) revert AssetNotSupported(_vault, _asset);
    }

    function _validateBorrow(address _borrower, address _asset, uint256 _amount) internal {
        if (!registry.supportedBorrower(_vault, _asset)) revert BorrowerNotSupported(_borrower);
        if (_amount > availableBorrow(_asset)) 
            revert NotEnoughCash(_amount, availableBorrow(_asset));

        uint256 assetPrice = oracle.getPrice(_asset);
        uint256 borrowValue = _amount * assetPrice;
        uint256 currentBorrowValue = reserve[_vault][_asset].borrowed[_borrower] * assetPrice;
        uint256 borrowCapacity = (avs.getCollateralValue(_borrower) * reserve[_vault][_asset].ltv * score) 
            - currentBorrowValue;
        
        if (borrowValue > borrowCapacity) 
            revert BorrowOverCollateralBacking(borrowValue, borrowCapacity);
    }
}
