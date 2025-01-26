// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 __decimals) ERC20(name, symbol) {
        _decimals = __decimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function mockDecimals(uint8 __decimals) external {
        _decimals = __decimals;
    }

    function mockMinimumTotalSupply(uint256 _totalSupply) external {
        if (_totalSupply > totalSupply()) {
            _mint(address(this), _totalSupply - totalSupply());
        }
    }
}
