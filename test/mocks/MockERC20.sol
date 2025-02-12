// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        require(amount <= 1e50, "Amount must be less than 1e50");

        _mint(to, amount);
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
        require(totalSupply_ <= 1e50, "Total supply must be less than 1e50");

        if (totalSupply_ > totalSupply()) {
            _mint(address(this), totalSupply_ - totalSupply());
        }
    }
}
