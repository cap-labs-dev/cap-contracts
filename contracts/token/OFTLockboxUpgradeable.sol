// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OFTAdapterUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTAdapterUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title OFT Lockbox
/// @author kexley & weso, Cap Labs, LayerZero Labs
contract OFTLockboxUpgradeable is OFTAdapterUpgradeable, UUPSUpgradeable {
    /// @param _token Token address
    /// @param _lzEndpoint Layerzero endpoint
    constructor(address _token, address _lzEndpoint) OFTAdapterUpgradeable(_token, _lzEndpoint) {
        _disableInitializers();
    }

    /// @dev Initialize the cap token lockbox
    /// @param _delegate Delegate capable of making OApp changes
    function initialize(address _delegate) external initializer {
        // Initialize ownership first
        __Ownable_init(_delegate);

        // Initialize OFTAdapter
        __OFTAdapter_init(_delegate);

        // Initialize UUPS
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }
}
