// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LendingPool is Initializable, AccessControlEnumerableUpgradeable {

    ICapToken public capToken;

    struct Reserve {
        uint256 totalSupplies;
        uint256 totalBorrows;
        uint256 index;
        uint256 lastUpdate;
        uint256 withdrawReserve;
        uint256 ltv;
        uint256 cap;
        mapping(address => uint256) borrow;
        mapping(address => uint256) accrued;
        mapping(address => uint256) borrowerIndex;
        mapping(address => uint256) queue;
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

    function initialize(address _capToken) initializer external {
        capToken = ICapToken(_capToken);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function supply(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver
    ) external returns (uint256 amountOut) {
        _validateAsset(_asset);
        _updateIndex(_asset);
        amountOut = _getMint(_asset, _amountIn);
        if (amountOut < _minAmountOut) revert Slippage(amountOut, _minAmountOut);
        reserve[_asset].totalSupplies += _amountIn;
        capToken.mint(msg.sender, amountOut);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amountIn);
    }

    function withdraw(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver
    ) external returns (uint256 amountOut, uint256 queued) {
        _validateAsset(_asset);
        _updateIndex(_asset);
        amountOut = _getBurn(_asset, _amountIn);
        if (amountOut < _minAmountOut) revert Slippage(amountOut, _minAmountOut);
        reserve[_asset].totalSupplies -= amountOut;
        capToken.burn(msg.sender, _amountIn);

        // Add asset to withdrawal queue if not enough is available
        uint256 currentBalance = IERC20(_asset).balanceOf(address(this));
        currentBalance = currentBalance > reserve[_asset].withdrawReserve 
            ? currentBalance - reserve[_asset].withdrawReserve 
            : 0;
        if (currentBalance < amountOut) {
            queued = amountOut - currentBalance;
            amountOut -= queued;
            reserve[_asset].queue[_receiver] += queued;
            reserve[_asset].withdrawReserve += queued;
        }

        if (amountOut > 0) IERC20(asset).safeTransfer(_receiver, amountOut);
    }

    function borrow(address _asset, uint256 _amount, address _receiver) external {
        _validateAsset(_asset);
        _validateBorrow(msg.sender, _asset, _amount);
        _accrueInterest(_asset, msg.sender);
        reserve[_asset].borrow[msg.sender] += _amount;
        reserve[_asset].totalBorrows += _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);
    }

    function repay(address _asset, uint256 _amount, address _onBehalfOf) external {
        _validateAsset(_asset);
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
                reserve[_asset].borrow[_onBehalfOf] -= principlePaid;
                reserve[_asset].totalBorrows -= principlePaid;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, interest);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principlePaid);
            } else {
                uint256 overpay = _amount - principal;
                reserve[_asset].borrow[_onBehalfOf] = 0;
                reserve[_asset].totalBorrows -= principal;
                IERC20(_asset).safeTransferFrom(msg.sender, rewarder, overpay);
                IERC20(_asset).safeTransferFrom(msg.sender, address(this), principal);
            }
        }
    }

    function _accrueInterest(address _asset, address _borrower) internal {
        _updateIndex(_asset);
        reserve[_asset].accrued[_borrower] = accruedInterest(_asset, _borrower);
        reserve[_asset].borrowerIndex[_borrower] = index[_asset];
    }

    function _updateIndex(address _asset) internal {
        uint256 borrowRate = _getBorrowRate(_asset);
        reserve[_asset].index += borrowRate * ( block.timestamp - reserve[_asset].lastUpdate );
        reserve[_asset].lastUpdate = block.timestamp;
    }

    function _getBorrowRate(address _asset) internal returns (uint256 rate) {
        uint256 borrowUsageRatio = reserve[_asset].totalBorrows / reserve[_asset].totalSupplies;
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
        uint256 index = reserve[_asset].index 
            + ( borrowRate * ( block.timestamp - reserve[_asset].lastUpdate ) );
        interest = ( reserve[_asset].borrow[_borrower] + reserve[_asset].accrued[_borrower] ) 
            * ( index - reserve[_asset].borrowerIndex[_borrower] );
    }

    function availableBorrow(address _asset) public view returns (uint256 available) {
        uint256 balance = IERC20(_asset).balanceOf(address(this));
        available = balance > reserve[_asset].withdrawReserve 
            ? balance - reserve[_asset].withdrawReserve 
            : 0;
    }

    /* -------------------- MINT/BURN LOGIC -------------------- */

    function _getMint(address _asset, uint256 _amount) internal returns (uint256 amountOut) {
        
    }

    function _getBurn(address _asset, uint256 _amount) internal returns (uint256 amountOut) {
        
    }

    /* -------------------- WITHDRAWAL QUEUE -------------------- */

    function claim(address _asset) external returns (uint256 amount) {
        amount = claimable(_asset, msg.sender);
        if (amount > 0) {
            reserve[_asset].queue[msg.sender] -= amount;
            reserve[_asset].withdrawReserve -= amount;
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
    }

    function claimable(address _asset, address _user) public view returns (uint256 amount) {
        amount = reserve[_asset].queue[_user];
        uint256 currentBalance = IERC20(_asset).balanceOf(address(this));
        if (amount > currentBalance) amount -= currentBalance;
    }

    /* -------------------- VALIDATION -------------------- */

    function _validateAsset(address _asset) internal {
        if (!supportedAsset[_asset]) revert AssetNotSupported(_asset);
    }

    function _validateBorrow(address _borrower, address _asset, uint256 _amount) internal {
        if (!supportedBorrower[_borrower]) revert NotValidBorrower(_borrower);
        if (reserve[_asset].totalBorrows + _amount > reserve[_asset].cap) 
            revert OverBorrowCap(reserve[_asset].totalBorrows + _amount, reserve[_asset].cap);
        if (_amount > availableBorrow(_asset)) 
            revert NotEnoughCash(_amount, availableBorrow(_asset));

        uint256 assetPrice = oracle.getPrice(_asset);
        uint256 borrowValue = _amount * assetPrice;
        uint256 currentBorrowValue = reserve[_asset].borrow[_borrower] * assetPrice;
        uint256 borrowCapacity = (avs.getCollateralValue(_borrower) * reserve[_asset].ltv) 
            - currentBorrowValue;
        
        if (borrowValue > borrowCapacity) 
            revert BorrowOverCollateralBacking(borrowValue, borrowCapacity);
    }
}
