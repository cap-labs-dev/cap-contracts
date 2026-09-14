// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IPremiumVesting } from "../interfaces/IPremiumVesting.sol";
import { IWrapper } from "../interfaces/IWrapper.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title Wrapper
/// @author kexley, Cap Labs
/// @notice ERC-4626 vault that holds the stablecoin and claims its vested premium into `totalAssets`
contract Wrapper layout at erc7201("cap.storage.Wrapper")
    is
    IWrapper,
    AccessManagedUpgradeable,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    UUPSUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IWrapper
    function initialize(address _authority, address _asset) external initializer {
        string memory _name = string.concat("Staked ", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("st", IERC20Metadata(_asset).symbol());

        __AccessManaged_init(_authority);
        __ERC4626_init(IERC20(_asset));
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);

        IPremiumVesting(address(asset())).optIn();
    }

    /// @inheritdoc IWrapper
    function totalAssets() public view override(ERC4626Upgradeable, IWrapper) returns (uint256 assets) {
        assets = super.totalAssets() + IPremiumVesting(address(asset())).claimable(address(this));
    }

    /// @inheritdoc IWrapper
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable, IWrapper) returns (uint8 _decimals) {
        _decimals = ERC4626Upgradeable.decimals();
    }

    /// @inheritdoc IERC4626
    /// @dev Empty vault quotes at par via {DeadShares-seedDeposit}.
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = totalSupply() == 0 ? DeadShares.seedDeposit(assets) : super.previewDeposit(assets);
    }

    /// @inheritdoc IERC4626
    /// @dev Inverse of {previewDeposit} while empty.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() == 0 ? DeadShares.seedMint(shares) : super.previewMint(shares);
    }

    /// @dev Claim vested premium into the vault before the deposit is priced
    /// @param _caller Caller of the deposit
    /// @param _receiver Receiver of the wrapper shares
    /// @param _assets Amount of the asset to pull from the caller
    /// @param _shares Amount of wrapper shares to mint to the receiver
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        IPremiumVesting(address(asset())).claim(address(this));
        if (totalSupply() == 0) _mint(DeadShares.HOLDER, DeadShares.SHARES);
        super._deposit(_caller, _receiver, _assets, _shares);
    }

    /// @dev Claim vested premium into the vault before the withdrawal is priced
    /// @param _caller Caller of the withdrawal
    /// @param _receiver Receiver of the asset
    /// @param _owner Owner of the wrapper shares being burned
    /// @param _assets Amount of the asset to send to the receiver
    /// @param _shares Amount of wrapper shares to burn from the owner
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
    {
        IPremiumVesting(address(asset())).claim(address(this));
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
