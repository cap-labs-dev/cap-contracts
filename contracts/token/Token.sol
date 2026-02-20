// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title Token
/// @author kexley, Cap Labs
/// @notice Token with permit capabilities and upgradeability
contract Token is ERC20PermitUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the token
    /// @param name Name of the token
    /// @param symbol Symbol of the token
    /// @param owner Owner of the token
    /// @param supply Supply of the token (18 decimals)
    function initialize(string memory name, string memory symbol, address owner, uint256 supply) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __Ownable_init(owner);
        __UUPSUpgradeable_init();

        _mint(owner, supply);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
