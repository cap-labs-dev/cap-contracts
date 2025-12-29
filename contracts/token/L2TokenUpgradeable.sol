// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OFTPermitUpgradeable } from "./OFTPermitUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title L2 Token
/// @author kexley & weso, Cap Labs, LayerZero Labs
/// @notice L2 Token with permit functions
contract L2TokenUpgradeable is OFTPermitUpgradeable, UUPSUpgradeable {
    /// @dev Initialize the L2 token
    constructor(address _lzEndpoint) OFTPermitUpgradeable(_lzEndpoint) { }

    function initialize(string memory _name, string memory _symbol, address _delegate) public initializer {
        __OFTPermit_init(_name, _symbol, _delegate);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
