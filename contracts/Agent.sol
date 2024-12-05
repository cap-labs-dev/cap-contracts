// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Agent is Initializable, AccessControlEnumerableUpgradeable {

    struct Reserve {
        uint256 borrowIndex;
        uint256 utilizationIndex;
        uint256 lastUpdate;
        uint256 ltv;
        mapping(address => uint256) borrowed;
        mapping(address => uint256) accrued;
        mapping(address => uint256) storedBorrowIndex;
    }

    struct BorrowRate {
        uint256 variableSlope1;
        uint256 variableSlope2;
        uint256 optimalUsageRatio;
    }

    mapping(address => Reserve) public reserve;
    mapping(address => BorrowRate) public borrowRates;

    address[] public assets;
    address[] public borrowers;
    mapping(address => bool) public supportedAssets;
    mapping(address => bool) public supportedBorrowers;

    function initialize() initializer external {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function borrow(address _vault, address _asset, uint256 _amount, address _receiver) external {
        _validateAsset(_vault, _asset);
        _validateBorrow(msg.sender, _asset, _amount);
        _accrueInterest(_asset, msg.sender);
        reserve[_asset].borrowed[msg.sender] += _amount;
        vault.borrow(_asset, _amount, _receiver);
    }

    function repay(address _vault, address _asset, uint256 _amount, address _onBehalfOf) external {
        _validateAsset(_vault, _asset);
        _accrueInterest(_asset, _onBehalfOf);
        uint256 principal = borrowed[_asset][_onBehalfOf];
        uint256 interest = accrued[_asset][_onBehalfOf];

        if (_amount < interest) {
            reserve[_asset].accrued[_onBehalfOf] -= _amount;
            IERC20(_asset).safeTransferFrom(msg.sender, rewarder, _amount);
        } else {
            reserve[_asset].accrued[_onBehalfOf] = 0;
            if (_amount < principal + interest) {
                uint256 principlePaid = _amount - interest;
                reserve[_asset].borrowed[_onBehalfOf] -= principlePaid;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, interest);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principlePaid);
                IERC20(_asset).forceApprove(address(vault), principlePaid);
                vault.repay(_asset, principlePaid);
            } else {
                uint256 overpay = _amount - principal;
                reserve[_asset].borrowed[_onBehalfOf] = 0;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, overpay);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principal);
                IERC20(_asset).forceApprove(address(vault), principlePaid);
                vault.repay(_asset, principal);
            }
        }
    }

    function _accrueInterest(address _asset, address _borrower) internal {
        _updateIndex(_asset);
        reserve[_asset].accrued[_borrower] = accruedInterest(_asset, _borrower);
        reserve[_asset].storedBorrowIndex[_borrower] = reserve[_asset].borrowIndex;
    }

    function _updateIndex(address _asset) internal {
        uint256 borrowRate = _getBorrowRate(_asset);
        reserve[_asset].borrowIndex += borrowRate * ( block.timestamp - reserve[_asset].lastUpdate );
        reserve[_asset].lastUpdate = block.timestamp;
    }

    function _getBorrowRate(address _asset) internal returns (uint256 rate) {
        uint256 borrowUsageRatio = ( vault.currentUtilizationIndex(_asset) - reserve[_asset].utilizationIndex ) 
            / (block.timestamp - reserve[_asset].lastUpdate);
        reserve[_asset].utilizationIndex = vault.currentUtilizationIndex(_asset);
        uint256 optimalUsageRatio = borrowRates[_asset].optimalUsageRatio;
        uint256 slope1 = borrowRates[_asset].variableSlope1;
        uint256 slope2 = borrowRates[_asset].variableSlope2;
        if (borrowUsageRatio > optimalUsageRatio) {
            uint256 excessBorrowUsageRatio = borrowUsageRatio - optimalUsageRatio;
            rate = slope1 + ( slope2 * excessBorrowUsageRatio );
        } else {
            rate = slope1 * borrowUsageRatio / optimalUsageRatio;
        }
    }

    function accruedInterest(
        address _asset,
        address _borrower
    ) public view returns (uint256 interest) {
        uint256 borrowRate = _getBorrowRate(_asset);
        uint256 borrowIndex = reserve[_asset].borrowIndex 
            + ( borrowRate * ( block.timestamp - reserve[_asset].lastUpdate ) );
        interest = ( reserve[_asset].borrowed[_borrower] + reserve[_asset].accrued[_borrower] ) 
            * ( borrowIndex - reserve[_asset].storedBorrowIndex[_borrower] );
    }

    function availableBorrow(address _asset) public view returns (uint256 available) {
        available = vault.balance(_asset);
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
        uint256 currentBorrowValue = reserve[_asset].borrowed[_borrower] * assetPrice;
        uint256 borrowCapacity = (avs.getCollateralValue(_borrower) * reserve[_asset].ltv) 
            - currentBorrowValue;
        
        if (borrowValue > borrowCapacity) 
            revert BorrowOverCollateralBacking(borrowValue, borrowCapacity);
    }
}
