// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { BeaconFactory } from "../../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Vault } from "../../../contracts/cap/Vault.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { ChainlinkAdapter } from "../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../contracts/cap/oracle/Oracle.sol";
import { IRegistry } from "../../../contracts/interfaces/IRegistry.sol";
import { CapRoles } from "../../../contracts/utils/CapRoles.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { CreateXUtils } from "../utils/CreateXUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DeployInfra is CreateXUtils {
    using SafeERC20 for IERC20;

    /// @dev One cUSD of unredeemable wrapper shares, plus {DeadShares} on the first deposit
    uint256 private constant WRAPPER_SEED = 1e18;

    /// @dev Deploy the shared infrastructure through CreateX and initialize it
    /// @param implementations The implementation addresses
    /// @param users The admin and token configuration
    /// @return infra The deployed infrastructure addresses
    function _deployInfra(ImplementationsConfig memory implementations, UsersConfig memory users)
        internal
        returns (InfraConfig memory infra)
    {
        infra = _deployInfra(implementations, users, bytes32(0));
    }

    /// @dev Deploy the shared infrastructure through CreateX and initialize it
    /// @param implementations The implementation addresses
    /// @param users The admin and token configuration
    /// @param saltNamespace Distinguishes otherwise identical deploys
    /// @return infra The deployed infrastructure addresses
    function _deployInfra(ImplementationsConfig memory implementations, UsersConfig memory users, bytes32 saltNamespace)
        internal
        returns (InfraConfig memory infra)
    {
        _requireTransientStorage();
        require(users.stablecoinUnderlying != address(0), "stablecoinUnderlying required");
        require(users.deployer != address(0), "deployer required");

        address deployer = users.deployer;

        // Temporary admin so this account can grant the Registry ADMIN before initialize.
        // {_initInfraAccessControl} moves ADMIN to `users.admin` and drops the deployer.
        infra.accessManager = _create3(
            _salt(deployer, saltNamespace, "accessManager"),
            abi.encodePacked(type(AccessManager).creationCode, abi.encode(deployer))
        );

        infra.vault = _create3Proxy(
            _salt(deployer, saltNamespace, "vault"),
            implementations.vault,
            abi.encodeCall(Vault.initialize, (infra.accessManager))
        );

        // Deployed here rather than passed in. Handing the registry a foreign address meant the
        // real oracle was never built or read by anything that runs, so its answer scale went
        // unchecked against the consumers that carry it into collateral value. The adapter is
        // stateless and holds no per-asset configuration, so one instance serves every feed; the
        // governor still has to point each asset at it with {Oracle-setSource} before that asset
        // can back a market, which {Registry} enforces by pricing it at launch
        infra.oracle = _create3Proxy(
            _salt(deployer, saltNamespace, "oracle"),
            implementations.oracle,
            abi.encodeCall(Oracle.initialize, (infra.accessManager))
        );
        infra.chainlinkAdapter =
            _create3(_salt(deployer, saltNamespace, "chainlinkAdapter"), type(ChainlinkAdapter).creationCode);

        // CREATE3 addresses do not depend on initcode, so the circular IRM / stablecoin pair
        // can be predicted before either proxy exists
        address irmAddr = _predictCreate3(_salt(deployer, saltNamespace, "irm"), deployer);
        address stablecoinAddr = _predictCreate3(_salt(deployer, saltNamespace, "stablecoin"), deployer);

        infra.irm = _create3Proxy(
            _salt(deployer, saltNamespace, "irm"),
            implementations.irm,
            abi.encodeCall(
                InterestRateModel.initialize, (infra.accessManager, stablecoinAddr, 1e27, 2e27, 1e27, 0.02e27, 1 hours)
            )
        );

        infra.stablecoin = _create3Proxy(
            _salt(deployer, saltNamespace, "stablecoin"),
            implementations.stablecoin,
            abi.encodeCall(
                Stablecoin.initialize,
                (infra.accessManager, users.stablecoinUnderlying, "Cap USD", "cUSD", irmAddr, users.reserveVault)
            )
        );

        require(infra.irm == irmAddr, "irm addr");
        require(infra.stablecoin == stablecoinAddr, "stablecoin addr");

        infra.wrapper = _create3Proxy(
            _salt(deployer, saltNamespace, "wrapper"),
            implementations.wrapper,
            abi.encodeCall(Wrapper.initialize, (infra.accessManager, infra.stablecoin))
        );
        _seedWrapper(infra.wrapper, infra.stablecoin, users.stablecoinUnderlying);

        infra.factory = _create3Proxy(
            _salt(deployer, saltNamespace, "factory"),
            address(new BeaconFactory()),
            abi.encodeCall(BeaconFactory.initialize, (infra.accessManager))
        );
        // Ownable beacons, owned by the AccessManager so upgrades go through {IAccessManager-execute}
        infra.floatingMarketBeacon = _create3(
            _salt(deployer, saltNamespace, "floatingMarketBeacon"),
            abi.encodePacked(
                type(UpgradeableBeacon).creationCode, abi.encode(implementations.floatingMarket, infra.accessManager)
            )
        );
        infra.fixedMarketBeacon = _create3(
            _salt(deployer, saltNamespace, "fixedMarketBeacon"),
            abi.encodePacked(
                type(UpgradeableBeacon).creationCode, abi.encode(implementations.fixedMarket, infra.accessManager)
            )
        );
        infra.trancheBeacon = _create3(
            _salt(deployer, saltNamespace, "trancheBeacon"),
            abi.encodePacked(
                type(UpgradeableBeacon).creationCode, abi.encode(implementations.tranche, infra.accessManager)
            )
        );
        infra.underwriterBeacon = _create3(
            _salt(deployer, saltNamespace, "underwriterBeacon"),
            abi.encodePacked(
                type(UpgradeableBeacon).creationCode, abi.encode(implementations.underwriter, infra.accessManager)
            )
        );

        // {Registry-initialize} wires every shared selector, which is an ADMIN call on the
        // manager. Grant that before the proxy is created so the initializer can do its job
        address registryAddr = _predictCreate3(_salt(deployer, saltNamespace, "registry"), deployer);
        AccessManager(infra.accessManager).grantRole(CapRoles.ADMIN, registryAddr, 0);
        AccessManager(infra.accessManager).grantRole(CapRoles.REGISTRY, registryAddr, 0);

        infra.registry = _create3Proxy(
            _salt(deployer, saltNamespace, "registry"),
            implementations.registry,
            abi.encodeCall(
                Registry.initialize,
                (
                    infra.accessManager,
                    IRegistry.InitParams({
                        stablecoin: infra.stablecoin,
                        vault: infra.vault,
                        oracle: infra.oracle,
                        irm: infra.irm,
                        factory: infra.factory,
                        floatingMarketBeacon: infra.floatingMarketBeacon,
                        fixedMarketBeacon: infra.fixedMarketBeacon,
                        trancheBeacon: infra.trancheBeacon,
                        underwriterBeacon: infra.underwriterBeacon,
                        lt: 0.8e27,
                        buffer: 0.1e27,
                        targetHealth: 1.25e27
                    })
                )
            )
        );

        require(infra.registry == registryAddr, "registry addr");
    }

    /// @dev Permissioned CreateX salt for `key` under `namespace`
    function _salt(address deployer, bytes32 namespace, bytes32 key) private pure returns (bytes32 salt) {
        salt = _createXSalt(deployer, namespace, key);
    }

    /// @dev Markets use {ReentrancyGuardTransient}; fail now if this chain has no EIP-1153.
    function _requireTransientStorage() private {
        assembly {
            tstore(0, 1)
            if iszero(eq(tload(0), 1)) { revert(0, 0) }
        }
    }

    /// @dev Deposit 1 cUSD into the wrapper and leave the shares on {DeadShares-HOLDER}
    function _seedWrapper(address wrapper, address stablecoin, address underlying) private {
        uint256 seedAssets = Stablecoin(stablecoin).previewMint(WRAPPER_SEED);
        IERC20 token = IERC20(underlying);
        require(token.balanceOf(address(this)) >= seedAssets, "wrapper seed");
        token.forceApprove(stablecoin, seedAssets);
        uint256 cusd = Stablecoin(stablecoin).deposit(seedAssets, address(this));
        IERC20(stablecoin).forceApprove(wrapper, cusd);
        Wrapper(wrapper).deposit(cusd, DeadShares.HOLDER);
    }
}
