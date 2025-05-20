// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockVault is ERC20 {
    using SafeERC20 for IERC20Metadata;

    uint8 private _decimals;

    uint256 public constant MAX_MINT = 1e50;
    uint256 public constant MAX_TOTAL_SUPPLY = 1e50;

    error DeadlinePassed();
    error ZeroAmount();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address _asset, uint256 _amountIn, uint256 _minAmountOut, address _receiver, uint256 _deadline)
        external
        returns (uint256 amountOut)
    {
        if (_deadline < block.timestamp) revert DeadlinePassed();
        if (_amountIn == 0) revert ZeroAmount();
        if (_receiver == address(0) || _asset == address(0)) revert ZeroAddress();

        IERC20Metadata(_asset).safeTransferFrom(msg.sender, address(this), _amountIn);

        amountOut = _amountIn * 1e18 / 10 ** IERC20Metadata(_asset).decimals();
        if (amountOut < _minAmountOut) revert ZeroAmount();
        _mint(_receiver, amountOut);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mockDecimals(uint8 decimals_) external {
        require(decimals_ <= 50, "Decimals must be less than 50");
        _decimals = decimals_;
    }

    function mockMinimumTotalSupply(uint256 totalSupply_) external {
        require(totalSupply_ <= MAX_TOTAL_SUPPLY, "Total supply must be less than MAX_TOTAL_SUPPLY");

        if (totalSupply_ > totalSupply()) {
            _mint(address(this), totalSupply_ - totalSupply());
        }
    }

    function getMintAmount(address, uint256 _amountIn) external pure returns (uint256 amountOut, uint256 fee) {
        return (_amountIn * 1e18 / 1e6, 0);
    }
}
