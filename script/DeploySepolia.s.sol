// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../contracts/cap/InterestRateModel.sol";
import { Registry } from "../contracts/cap/Registry.sol";
import { Stablecoin } from "../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../contracts/cap/Wrapper.sol";
import { ChainlinkAdapter } from "../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IChainlink } from "../contracts/interfaces/IChainlink.sol";
import { IInterestRateModel } from "../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../contracts/interfaces/IOracle.sol";
import { CapRoles } from "../contracts/utils/CapRoles.sol";
import { DeadShares } from "../contracts/utils/DeadShares.sol";
import { InfraSerializer } from "./config/InfraSerializer.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "./deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "./deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "./deploy/service/DeployImplems.sol";
import { DeployInfra } from "./deploy/service/DeployInfra.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @title DeploySepolia
/// @notice Fresh infrastructure with Circle USDC and a WETH/USD oracle, run by any wallet.
/// @dev The signing wallet is the deployer: it pays the wrapper seed, holds every protocol role
/// and keys the CreateX salts, so each wallet gets its own stack. `run()` never writes config.
/// After a successful broadcast, run `save()` from the same wallet without --broadcast to
/// validate the deployed contracts and record them, and their deployer, in config/cap-v2.json.
contract DeploySepolia is Script, InfraSerializer, DeployImplems, DeployInfra, ConfigureAccessControl {
    uint256 public constant CHAIN_ID = 11155111;
    address public constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    bytes32 public constant DEFAULT_NAMESPACE = keccak256("cap-network-sepolia-v1");
    // Testnet policy: reject answers older than two hours. No fixed-price fallback.
    uint256 public constant FEED_MAX_AGE = 2 hours;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Simulate, or broadcast when the caller passes --broadcast, a fresh deployment.
    function run() external returns (ImplementationsConfig memory implems, InfraConfig memory infra) {
        require(block.chainid == CHAIN_ID, "Sepolia only");
        address deployer = _deployer();
        require(address(CREATEX).code.length > 0, "CreateX missing");
        require(USDC.code.length > 0 && IERC20Metadata(USDC).decimals() == 6, "invalid USDC");
        require(WETH.code.length > 0 && IERC20Metadata(WETH).decimals() == 18, "invalid WETH");
        require(IERC20Metadata(USDC).balanceOf(deployer) >= 1e6, "need 1 USDC for wrapper seed");
        _checkFeed();

        bytes32 namespace = vm.envOr("SALT_NAMESPACE", DEFAULT_NAMESPACE);
        InfraConfig memory predicted = _predictInfra(deployer, namespace);
        address[13] memory targets = _targets(predicted);
        for (uint256 i; i < targets.length; ++i) {
            require(targets[i].code.length == 0, "namespace already used");
        }

        UsersConfig memory users = UsersConfig({
            deployer: deployer,
            governor: deployer,
            keeper: deployer,
            guardian: deployer,
            admin: deployer,
            liquidator: deployer,
            stablecoinUnderlying: USDC,
            reserveVault: address(0)
        });

        vm.startBroadcast(deployer);
        implems = _deployImplementations();
        infra = _deployInfra(implems, users, namespace);
        _initInfraAccessControl(infra, users);
        // Testnet operator creates markets and underwriter pools without a follow-up admin step
        IAccessManager(infra.accessManager).grantRole(CapRoles.WHITELISTED, deployer, 0);
        // Match the test fixture's nonzero curve: 5% base, 10% at 80% utilization, 20% at 100%.
        InterestRateModel(infra.irm)
            .setLiquiditySlopes(
                IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
            );

        IOracle.Sources[] memory sources = new IOracle.Sources[](1);
        sources[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, ETH_USD),
            staleness: FEED_MAX_AGE
        });
        IOracle(infra.oracle).setSource(WETH, sources);
        vm.stopBroadcast();

        require(keccak256(abi.encode(infra)) == keccak256(abi.encode(predicted)), "address mismatch");
        _checkDeployment(infra, deployer);
        _print(infra, deployer, namespace);
    }

    /// @notice Validate a completed deployment and save its addresses to config/cap-v2.json.
    /// @dev Read-only onchain. Run from the deploying wallet immediately after deployment, before
    /// granting roles or using the stack. Replaces the Sepolia entry, including its deployer.
    function save() external {
        require(block.chainid == CHAIN_ID, "Sepolia only");
        address deployer = _deployer();
        bytes32 namespace = vm.envOr("SALT_NAMESPACE", DEFAULT_NAMESPACE);
        InfraConfig memory infra = _predictInfra(deployer, namespace);
        _checkDeployment(infra, deployer);

        ImplementationsConfig memory implems = ImplementationsConfig({
            vault: _implementation(infra.vault),
            stablecoin: _implementation(infra.stablecoin),
            irm: _implementation(infra.irm),
            oracle: _implementation(infra.oracle),
            registry: _implementation(infra.registry),
            floatingMarket: IBeacon(infra.floatingMarketBeacon).implementation(),
            fixedMarket: IBeacon(infra.fixedMarketBeacon).implementation(),
            tranche: IBeacon(infra.trancheBeacon).implementation(),
            underwriter: IBeacon(infra.underwriterBeacon).implementation(),
            wrapper: _implementation(infra.wrapper)
        });
        // The checked-in Sepolia entry supplies the token metadata preserved by the serializer.
        require(_readAccount("stablecoinUnderlying") == USDC, "config USDC mismatch");
        require(_readAccount("reserveVault") == address(0), "config reserve vault mismatch");
        _saveInfra(implems, infra, deployer);
        _print(infra, deployer, namespace);
        console.log("Saved verified Sepolia deployment to config/cap-v2.json");
    }

    /// @dev The wallet Forge signs with: --private-key/--account, or --sender when simulating
    function _deployer() private view returns (address deployer) {
        deployer = msg.sender;
        require(deployer != DEFAULT_SENDER, "no deployer: pass a wallet or --sender");
    }

    function _checkFeed() private view {
        require(ETH_USD.code.length > 0, "ETH/USD feed missing");
        (, int256 answer,, uint256 updatedAt,) = IChainlink(ETH_USD).latestRoundData();
        require(answer > 0 && IChainlink(ETH_USD).decimals() == 8, "invalid ETH/USD price");
        require(updatedAt > 0 && updatedAt <= block.timestamp, "invalid ETH/USD timestamp");
        require(block.timestamp - updatedAt <= FEED_MAX_AGE, "stale ETH/USD feed");
    }

    function _checkDeployment(InfraConfig memory infra, address deployer) private view {
        address[13] memory targets = _targets(infra);
        for (uint256 i; i < targets.length; ++i) {
            require(targets[i].code.length > 0, "deployment incomplete");
        }

        IAccessManager manager = IAccessManager(infra.accessManager);
        _requireRole(manager, CapRoles.ADMIN, deployer);
        _requireRole(manager, CapRoles.GOVERNOR, deployer);
        _requireRole(manager, CapRoles.GUARDIAN, deployer);
        _requireRole(manager, CapRoles.KEEPER, deployer);
        _requireRole(manager, CapRoles.LIQUIDATOR, deployer);
        _requireRole(manager, CapRoles.ADMIN, infra.registry);
        _requireRole(manager, CapRoles.REGISTRY, infra.registry);
        _requireRole(manager, CapRoles.WHITELISTED, deployer);

        Registry registry = Registry(infra.registry);
        require(registry.marketsLength() == 0 && registry.underwritersLength() == 0, "expected infrastructure only");
        require(registry.stablecoin() == infra.stablecoin && registry.oracle() == infra.oracle, "registry mismatch");
        require(registry.irm() == infra.irm && registry.wrapper() == infra.wrapper, "registry wiring mismatch");
        Stablecoin stablecoin = Stablecoin(infra.stablecoin);
        require(stablecoin.asset() == USDC && stablecoin.irm() == infra.irm, "stablecoin mismatch");
        require(stablecoin.reserveVault() == address(0), "unexpected reserve vault");
        require(InterestRateModel(infra.irm).stablecoin() == infra.stablecoin, "IRM mismatch");
        (uint256 base, uint256 slope0, uint256 slope1, uint256 kink) = InterestRateModel(infra.irm).liquiditySlopes();
        require(base == 0.05e27 && slope0 == 0.05e27 && slope1 == 0.1e27 && kink == 0.8e27, "rate curve mismatch");
        Wrapper wrapper = Wrapper(infra.wrapper);
        require(wrapper.asset() == infra.stablecoin, "wrapper mismatch");
        require(wrapper.balanceOf(DeadShares.HOLDER) >= 1e18, "wrapper seed missing");
        require(stablecoin.balanceOf(infra.wrapper) >= 1e18, "wrapper backing missing");

        IOracle.Sources[] memory sources = IOracle(infra.oracle).sources(WETH);
        require(sources.length == 1 && sources[0].primary.adapter == infra.chainlinkAdapter, "WETH adapter mismatch");
        require(sources[0].primary.staleness == FEED_MAX_AGE, "WETH freshness mismatch");
        require(
            keccak256(sources[0].primary.payload)
                == keccak256(abi.encodeWithSelector(ChainlinkAdapter.price.selector, ETH_USD)),
            "WETH feed mismatch"
        );
        _checkFeed();
        require(IOracle(infra.oracle).price(WETH) > 0, "WETH price unavailable");
    }

    function _requireRole(IAccessManager manager, uint64 role, address account) private view {
        (bool member, uint32 delay) = manager.hasRole(role, account);
        require(member && delay == 0, "role missing or delayed");
    }

    function _predictInfra(address deployer, bytes32 namespace) private view returns (InfraConfig memory infra) {
        infra.accessManager = _predict(deployer, namespace, "accessManager");
        infra.vault = _predict(deployer, namespace, "vault");
        infra.stablecoin = _predict(deployer, namespace, "stablecoin");
        infra.irm = _predict(deployer, namespace, "irm");
        infra.oracle = _predict(deployer, namespace, "oracle");
        infra.chainlinkAdapter = _predict(deployer, namespace, "chainlinkAdapter");
        infra.registry = _predict(deployer, namespace, "registry");
        infra.factory = _predict(deployer, namespace, "factory");
        infra.floatingMarketBeacon = _predict(deployer, namespace, "floatingMarketBeacon");
        infra.fixedMarketBeacon = _predict(deployer, namespace, "fixedMarketBeacon");
        infra.trancheBeacon = _predict(deployer, namespace, "trancheBeacon");
        infra.underwriterBeacon = _predict(deployer, namespace, "underwriterBeacon");
        infra.wrapper = _predict(deployer, namespace, "wrapper");
    }

    function _predict(address deployer, bytes32 namespace, bytes32 key) private view returns (address) {
        return _predictCreate3(_createXSalt(deployer, namespace, key), deployer);
    }

    function _targets(InfraConfig memory infra) private pure returns (address[13] memory) {
        return [
            infra.accessManager,
            infra.vault,
            infra.stablecoin,
            infra.irm,
            infra.oracle,
            infra.chainlinkAdapter,
            infra.registry,
            infra.factory,
            infra.floatingMarketBeacon,
            infra.fixedMarketBeacon,
            infra.trancheBeacon,
            infra.underwriterBeacon,
            infra.wrapper
        ];
    }

    function _implementation(address proxy) private view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(implementation.code.length > 0, "implementation missing");
    }

    function _print(InfraConfig memory infra, address deployer, bytes32 namespace) private view {
        console.log("Sepolia chain ID", block.chainid);
        console.log("Deployer/admin", deployer);
        console.log("Salt namespace");
        console.logBytes32(namespace);
        console.log("accessManager", infra.accessManager);
        console.log("vault        ", infra.vault);
        console.log("registry     ", infra.registry);
        console.log("stablecoin   ", infra.stablecoin);
        console.log("wrapper      ", infra.wrapper);
        console.log("oracle       ", infra.oracle);
        console.log("adapter      ", infra.chainlinkAdapter);
        console.log("irm          ", infra.irm);
        console.log("factory      ", infra.factory);
        console.log("WETH/USD, 18 decimals", IOracle(infra.oracle).price(WETH));
        console.log("Market creation whitelist: deployer");
    }
}
