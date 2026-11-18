// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetERC20
/// @notice Mintable ERC20 for testnet deployments. Only the owner can mint, so test balances
/// stay under the admin's control and the token cannot be flooded by anyone with a faucet link.
/// @dev Not for production. Decimals are fixed at construction so a 6-decimal reserve token and
/// an 8-decimal collateral can sit beside 18-decimal ones, as they would on mainnet.
contract TestnetERC20 is ERC20, Ownable {
    uint8 private immutable DECIMALS;

    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param decimals_ Token decimals
    /// @param admin The only account allowed to mint; also the owner
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address admin)
        ERC20(name_, symbol_)
        Ownable(admin)
    {
        DECIMALS = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mint `amount` to `to`. Owner only.
    /// @param to The recipient
    /// @param amount The amount in this token's decimals
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Mint to several recipients in one transaction. Owner only.
    /// @param to The recipients
    /// @param amounts The amount for each recipient, in this token's decimals
    function mintBatch(address[] calldata to, uint256[] calldata amounts) external onlyOwner {
        require(to.length == amounts.length, "length");
        for (uint256 i; i < to.length; ++i) {
            _mint(to[i], amounts[i]);
        }
    }

    /// @notice Burn `amount` from the caller
    /// @param amount The amount in this token's decimals
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
