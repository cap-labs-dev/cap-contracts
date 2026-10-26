// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Registry } from "../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev v1 stcUSD values shares at `storedTotal - lockedProfit()`, which is `totalAssets()`
interface IStakedCapV1 {
    function totalAssets() external view returns (uint256 total);
}

/// @title MigrateInfra
/// @notice Upgrade the live cUSD and stcUSD proxies onto the v2 implementations
/// @dev Caller must already be allowed to `upgradeToAndCall` on the v1 AccessControl.
///
///      stcUSD runbook. v1 releases yield over `lockDuration`; v2 values stcUSD at its whole cUSD
///      balance, so anything still locked or un-notified would enter the share price at once.
///      1. At least one `lockDuration` before the upgrade, point `FeeReceiver.setStakedCapToken`
///         at a holding address so fee auction proceeds stop reaching stcUSD.
///      2. If stcUSD holds an un-notified balance, call its `notify()` and wait `lockDuration`.
///      3. Run the upgrade. {_upgradeExistingTokens} reverts if the share price would jump by more
///         than {MAX_STAKED_PRICE_JUMP}.
///      4. Return the held fees with `Stablecoin.fund`, redeeming any cUSD to the underlying first.
///         They vest to every opted-in cUSD holder, stcUSD included, without a share-price jump.
contract MigrateInfra {
    /// @dev Largest stcUSD share-price jump the upgrade accepts, as a fraction of v1 assets (1 bp).
    ///      Exact equality would let anyone block the migration with a 1 wei donation.
    uint256 internal constant MAX_STAKED_PRICE_JUMP = 10_000;

    /// @dev Point the live proxies at the new implementations and run `reinitializer(2)`.
    ///      cUSD first: the wrapper initializer opts into the new vest, which only exists
    ///      after cUSD has been upgraded. Reverts while v1 stcUSD holds more than 1 bp of locked
    ///      profit plus un-notified balance: v2 values stcUSD at its whole cUSD balance, so both
    ///      would enter the share price at once.
    /// @param implementations The new implementation addresses
    /// @param infra The infrastructure, including the live token proxies and the new IRM
    /// @param users Token configuration (`stablecoinUnderlying`, `reserveVault`)
    /// @param name Live cUSD name, so the ERC-2612 domain does not move
    /// @param symbol Live cUSD symbol
    function _upgradeExistingTokens(
        ImplementationsConfig memory implementations,
        InfraConfig memory infra,
        UsersConfig memory users,
        string memory name,
        string memory symbol
    ) internal {
        uint256 stakedAssets = IStakedCapV1(infra.wrapper).totalAssets();
        uint256 jump = IERC20(infra.stablecoin).balanceOf(infra.wrapper) - stakedAssets;
        require(jump <= stakedAssets / MAX_STAKED_PRICE_JUMP, "stcUSD share price would jump");

        UUPSUpgradeable(infra.stablecoin)
            .upgradeToAndCall(
                implementations.stablecoin,
                abi.encodeCall(
                    Stablecoin.initialize,
                    (
                        infra.accessManager,
                        users.stablecoinUnderlying,
                        name,
                        symbol,
                        infra.irm,
                        users.reserveVault,
                        Registry(implementations.registry).DEFAULT_VESTING_PERIOD()
                    )
                )
            );
        UUPSUpgradeable(infra.wrapper)
            .upgradeToAndCall(
                implementations.wrapper, abi.encodeCall(Wrapper.initialize, (infra.accessManager, infra.stablecoin))
            );
    }
}
