// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title L2 Token
/// @author kexley & weso, Cap Labs, LayerZero Labs
/// @notice L2 Token with permit functions
contract L2TokenUpgradeable is OFTUpgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    /// @dev Initialize the L2 token
    /// @param _lzEndpoint The LayerZero endpoint address
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    /// @dev Initialize the L2 token
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    /// @param _delegate The delegate to be set
    function initialize(string memory _name, string memory _symbol, address _delegate) external initializer {
        // Initialize ownership first
        __Ownable_init(_delegate);

        // Initialize OFT (which calls __ERC20_init internally)
        __OFT_init(_name, _symbol, _delegate);

        // Initialize Permit after ERC20 is initialized
        __ERC20Permit_init(_name);

        // Initialize UUPS
        __UUPSUpgradeable_init();
    }

    /// @dev Authorize the upgrade
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
