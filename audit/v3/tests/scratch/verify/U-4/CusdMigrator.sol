// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Verification scaffolding for U-4. A throw-away UUPS implementation the v1 timelock can route the
// cUSD proxy through inside ONE `upgradeToAndCall`. It shows which of U-4's three "unreachable"
// buckets migration code can pull in by itself (the two ERC-4626 fractional-reserve positions) and
// which it cannot (USDC on loan to v1 agents), and that a reserve guard can refuse the upgrade.

import { StablecoinV2 } from "../../U/StablecoinV2.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CusdMigrator is ERC20Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error ReserveShortfall(uint256 requiredUsdc, uint256 onHandUsdc);

    struct Params {
        address usdc;
        address frUsdc; // v1 fractional-reserve vault holding USDC (ERC-4626)
        address frOther; // v1 fractional-reserve vault holding the second basket asset
        address other; // the second basket asset (wWTGXX)
        address otherReceiver; // where the second asset goes for off-chain unwinding
        bool guard;
        address finalImpl;
        bytes finalData; // StablecoinV2.migrate(...) - a reinitializer(2), so `run` itself must not be one
    }

    constructor() {
        _disableInitializers();
    }

    /// no gate: the selector exists only for the duration of the upgrade transaction
    function run(Params calldata p) external {
        uint256 s1 = IERC20(p.frUsdc).balanceOf(address(this));
        if (s1 > 0) IERC4626(p.frUsdc).redeem(s1, address(this), address(this));
        uint256 s2 = IERC20(p.frOther).balanceOf(address(this));
        if (s2 > 0) IERC4626(p.frOther).redeem(s2, address(this), address(this));
        uint256 o = IERC20(p.other).balanceOf(address(this));
        if (o > 0) IERC20(p.other).safeTransfer(p.otherReceiver, o);

        if (p.guard) {
            uint256 onHand = IERC20(p.usdc).balanceOf(address(this));
            uint256 required = (totalSupply() + 1e12 - 1) / 1e12;
            if (onHand < required) revert ReserveShortfall(required, onHand);
        }
        ERC1967Utils.upgradeToAndCall(p.finalImpl, p.finalData);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("transient");
    }
}
