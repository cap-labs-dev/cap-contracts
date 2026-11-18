// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../contracts/cap/InterestRateModel.sol";
import { Registry } from "../contracts/cap/Registry.sol";
import { Stablecoin } from "../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../contracts/cap/Wrapper.sol";
import { IBaseMarket } from "../contracts/interfaces/IBaseMarket.sol";
import { IOracle } from "../contracts/interfaces/IOracle.sol";
import { TestnetERC20 } from "../contracts/testnet/TestnetERC20.sol";
import { CapRoles } from "../contracts/utils/CapRoles.sol";
import { DeadShares } from "../contracts/utils/DeadShares.sol";
import { InfraSerializer } from "./config/InfraSerializer.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "./deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "./deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "./deploy/service/DeployImplems.sol";
import { DeployInfra } from "./deploy/service/DeployInfra.sol";
import { SepoliaScenarios } from "./sepolia/SepoliaScenarios.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

/// @title DeploySepolia
/// @notice Fresh Cap Network on Ethereum Sepolia with admin-mintable test tokens and a full cast of
/// operators acting out the protocol's flows, so the UI has markets, pools, groups, debt, a
/// liquidation and queued exits to render from block one.
/// @dev The signing wallet is the deployer and admin: it pays gas and the wrapper seed, holds every
/// protocol role, owns the mock tokens and the wstETH feed, and keys the CreateX salts. The other
/// 24 actors are derived from `ACTORS_MNEMONIC` and funded in-script. `run()` never writes config;
/// `save()` validates a finished deployment and records it in `config/cap-v2.json`.
///
/// Environment:
///   ACTORS_MNEMONIC   BIP-39 phrase for the actors (required for a real broadcast)
///   ACTORS_INDEX_OFFSET first index to use on that phrase, default 0; set 1 when reusing the deployer's phrase
///   ACTOR_FUNDING     wei each actor is topped up to, default 0.05 ether
///   SALT_NAMESPACE    CreateX namespace, default keccak256("cap-network-sepolia-v2")
///   SCENARIO_WRITEOFF "true" to also crash the wstETH feed and write off debt (leaves bad debt)
///   SEPOLIA_MANIFEST  "true" to write config/sepolia-scenarios.json even on a dry run
contract DeploySepolia is
    Script,
    InfraSerializer,
    DeployImplems,
    DeployInfra,
    ConfigureAccessControl,
    SepoliaScenarios
{
    uint256 public constant CHAIN_ID = 11155111;
    bytes32 public constant DEFAULT_NAMESPACE = keccak256("cap-network-sepolia-v2");
    uint256 public constant DEFAULT_ACTOR_FUNDING = 0.05 ether;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Simulate, or broadcast with --broadcast, the deployment and every scenario.
    function run() external returns (ImplementationsConfig memory implems, InfraConfig memory deployed) {
        (implems, deployed) = runWith(vm.envOr("SCENARIO_WRITEOFF", false), vm.envOr("SEPOLIA_MANIFEST", false));
    }

    /// @notice {run} with the optional steps chosen explicitly rather than from the environment
    /// @param writeOff Also crash the wstETH feed and have the guardian write off debt (9.3)
    /// @param manifest Write config/sepolia-scenarios.json even when not broadcasting
    function runWith(bool writeOff, bool manifest)
        public
        returns (ImplementationsConfig memory implems, InfraConfig memory deployed)
    {
        require(block.chainid == CHAIN_ID, "Sepolia only");
        deployer = _deployer();
        namespace = vm.envOr("SALT_NAMESPACE", DEFAULT_NAMESPACE);
        bool broadcasting = _broadcasting();
        _deriveActors(
            vm.envOr("ACTORS_MNEMONIC", TEST_MNEMONIC),
            uint32(vm.envOr("ACTORS_INDEX_OFFSET", uint256(0))),
            broadcasting,
            deployer
        );
        uint256 funding = vm.envOr("ACTOR_FUNDING", DEFAULT_ACTOR_FUNDING);

        require(address(CREATEX).code.length > 0, "CreateX missing");
        _checkChainlinkFeed(ETH_USD, "ETH/USD");
        _checkChainlinkFeed(BTC_USD, "BTC/USD");
        require(deployer.balance > funding * ACTOR_COUNT, "deployer cannot fund the actors");

        InfraConfig memory predicted = _predictInfra(deployer, namespace);
        address[12] memory targets = _targets(predicted);
        for (uint256 i; i < targets.length; ++i) {
            require(targets[i].code.length == 0, "namespace already used");
        }
        address[7] memory tokens = _predictTokens(deployer, namespace);
        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i].code.length == 0, "namespace already used");
        }

        _printActors();

        // ── phase 0: tokens, then the protocol around them ─────────────────────
        _phaseTokens();
        require(address(mUsdc) == tokens[0], "token address mismatch");

        _s(
            "0.2",
            "Deploy Cap infrastructure through CreateX",
            "Implementations, proxies, beacons, registry, wrapper seed and protocol roles, all held by the deployer."
        );
        UsersConfig memory users = UsersConfig({
            deployer: deployer,
            governor: deployer,
            keeper: deployer,
            guardian: deployer,
            admin: deployer,
            liquidator: deployer,
            stablecoinUnderlying: address(mUsdc),
            reserveVault: address(0)
        });
        _asDeployer();
        implems = _deployImplementations();
        infra = _deployInfra(implems, users, namespace);
        _initInfraAccessControl(infra, users);
        IAccessManager(infra.accessManager).grantRole(CapRoles.WHITELISTED, deployer, 0);
        _done();
        require(keccak256(abi.encode(infra)) == keccak256(abi.encode(predicted)), "address mismatch");
        _bindHandles();

        _phaseOracle();

        // ── phases 1-12: the storyline ─────────────────────────────────────────
        _phaseProtocolRoles();
        _phaseFunding(funding);
        _phaseOperatorGroups();
        _phaseMarkets();
        _phaseBorrowerGroups();
        _phaseDepositorGroups();
        _phaseTrancheDeposits();
        _phaseStablecoinDeposits();
        _phaseUnderwriters();
        _phaseBorrowing();
        _phaseLiquidation(writeOff);
        _phaseMarketAdmin();
        _phaseGovernance();
        _phaseExits();

        _checkDeployment(infra, deployer);
        _checkScenarios();
        if (broadcasting || manifest) _writeManifest();
        _print(infra, deployer, namespace);
        deployed = infra;
    }

    /// @notice Validate a completed deployment and save its addresses to config/cap-v2.json.
    /// @dev Read-only onchain. Run from the deploying wallet after the broadcast finished.
    function save() external {
        require(block.chainid == CHAIN_ID, "Sepolia only");
        deployer = _deployer();
        namespace = vm.envOr("SALT_NAMESPACE", DEFAULT_NAMESPACE);
        infra = _predictInfra(deployer, namespace);
        address[7] memory tokens = _predictTokens(deployer, namespace);
        mUsdc = TestnetERC20(tokens[0]);
        mWeth = TestnetERC20(tokens[1]);
        mWbtc = TestnetERC20(tokens[2]);
        mWsteth = TestnetERC20(tokens[3]);
        _checkDeployment(infra, deployer);

        ImplementationsConfig memory implems = ImplementationsConfig({
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
        _saveSepolia(implems, infra, deployer, tokens);
        _print(infra, deployer, namespace);
        console.log("Saved verified Sepolia deployment to config/cap-v2.json");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev The wallet Forge signs with: --private-key/--account, or --sender when simulating
    function _deployer() private view returns (address wallet) {
        wallet = msg.sender;
        require(wallet != DEFAULT_SENDER, "no deployer: pass a wallet or --sender");
    }

    function _broadcasting() private view returns (bool yes) {
        yes = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _bindHandles() private {
        manager = IAccessManager(infra.accessManager);
        registry = Registry(infra.registry);
        cusd = Stablecoin(infra.stablecoin);
        stcusd = Wrapper(infra.wrapper);
    }

    function _checkDeployment(InfraConfig memory _infra, address wallet) private view {
        address[12] memory targets = _targets(_infra);
        for (uint256 i; i < targets.length; ++i) {
            require(targets[i].code.length > 0, "deployment incomplete");
        }
        require(address(mUsdc).code.length > 0 && IERC20Metadata(address(mUsdc)).decimals() == 6, "mUSDC missing");
        require(address(mWbtc).code.length > 0 && IERC20Metadata(address(mWbtc)).decimals() == 8, "mWBTC missing");

        IAccessManager _manager = IAccessManager(_infra.accessManager);
        _requireRole(_manager, CapRoles.ADMIN, wallet);
        _requireRole(_manager, CapRoles.GOVERNOR, wallet);
        _requireRole(_manager, CapRoles.GUARDIAN, wallet);
        _requireRole(_manager, CapRoles.KEEPER, wallet);
        _requireRole(_manager, CapRoles.LIQUIDATOR, wallet);
        _requireRole(_manager, CapRoles.WHITELISTED, wallet);
        _requireRole(_manager, CapRoles.ADMIN, _infra.registry);
        _requireRole(_manager, CapRoles.REGISTRY, _infra.registry);

        Registry _registry = Registry(_infra.registry);
        require(_registry.stablecoin() == _infra.stablecoin && _registry.oracle() == _infra.oracle, "registry mismatch");
        require(_registry.irm() == _infra.irm && _registry.wrapper() == _infra.wrapper, "registry wiring mismatch");
        Stablecoin stablecoin = Stablecoin(_infra.stablecoin);
        require(stablecoin.asset() == address(mUsdc) && stablecoin.irm() == _infra.irm, "stablecoin mismatch");
        require(stablecoin.reserveVault() == address(0), "unexpected reserve vault");
        require(InterestRateModel(_infra.irm).stablecoin() == _infra.stablecoin, "IRM mismatch");
        (uint256 base, uint256 slope0, uint256 slope1, uint256 kink) = InterestRateModel(_infra.irm).liquiditySlopes();
        require(base == 0.05e27 && slope0 == 0.05e27 && slope1 == 0.1e27 && kink == 0.8e27, "rate curve mismatch");
        Wrapper wrapper = Wrapper(_infra.wrapper);
        require(wrapper.asset() == _infra.stablecoin, "wrapper mismatch");
        require(wrapper.balanceOf(DeadShares.HOLDER) >= 1e18, "wrapper seed missing");
        require(stablecoin.balanceOf(_infra.wrapper) >= 1e18, "wrapper backing missing");
        require(IOracle(_infra.oracle).price(address(mWeth)) > 0, "mWETH price unavailable");
        require(IOracle(_infra.oracle).price(address(mWbtc)) > 0, "mWBTC price unavailable");
        require(IOracle(_infra.oracle).price(address(mWsteth)) > 0, "mwstETH price unavailable");
        require(TestnetERC20(address(mUsdc)).owner() == wallet, "mUSDC minter is not the admin");
    }

    /// @dev The storyline left the state it promised
    function _checkScenarios() private view {
        require(registry.marketsLength() == 4, "expected four markets");
        require(registry.underwritersLength() == 3, "expected three pools");
        require(IBaseMarket(atlas).totalDebt() > 0, "atlas has no debt");
        require(IBaseMarket(boreal).totalDebt() > 0, "boreal has no debt");
        require(IBaseMarket(cinderBtc).totalDebt() > 0, "cinder btc has no debt");
        require(IBaseMarket(cinderWsteth).totalDebt() > 0, "cinder steth has no debt");
        require(IBaseMarket(cinderWsteth).healthiness() >= 1e27, "cinder steth still unhealthy");
        require(manager.getTargetFunctionRole(atlas, IBaseMarket.setLoanToValue.selector) == atlasOwners, "atlas owner");
        require(registry.isOperatorRole(atlasBorrowersB) && registry.isOperatorRole(borealBorrowersB), "groups");
        require(mWsteth.balanceOf(liquidator.addr) > 0, "liquidator received nothing");
    }

    function _requireRole(IAccessManager _manager, uint64 role, address account) private view {
        (bool member, uint32 delay) = _manager.hasRole(role, account);
        require(member && delay == 0, "role missing or delayed");
    }

    function _predictInfra(address wallet, bytes32 ns) private view returns (InfraConfig memory predicted) {
        predicted.accessManager = _predict(wallet, ns, "accessManager");
        predicted.stablecoin = _predict(wallet, ns, "stablecoin");
        predicted.irm = _predict(wallet, ns, "irm");
        predicted.oracle = _predict(wallet, ns, "oracle");
        predicted.chainlinkAdapter = _predict(wallet, ns, "chainlinkAdapter");
        predicted.registry = _predict(wallet, ns, "registry");
        predicted.factory = _predict(wallet, ns, "factory");
        predicted.floatingMarketBeacon = _predict(wallet, ns, "floatingMarketBeacon");
        predicted.fixedMarketBeacon = _predict(wallet, ns, "fixedMarketBeacon");
        predicted.trancheBeacon = _predict(wallet, ns, "trancheBeacon");
        predicted.underwriterBeacon = _predict(wallet, ns, "underwriterBeacon");
        predicted.wrapper = _predict(wallet, ns, "wrapper");
    }

    function _predict(address wallet, bytes32 ns, bytes32 key) private view returns (address) {
        return _predictCreate3(_createXSalt(wallet, ns, key), wallet);
    }

    function _targets(InfraConfig memory _infra) private pure returns (address[12] memory) {
        return [
            _infra.accessManager,
            _infra.stablecoin,
            _infra.irm,
            _infra.oracle,
            _infra.chainlinkAdapter,
            _infra.registry,
            _infra.factory,
            _infra.floatingMarketBeacon,
            _infra.fixedMarketBeacon,
            _infra.trancheBeacon,
            _infra.underwriterBeacon,
            _infra.wrapper
        ];
    }

    function _implementation(address proxy) private view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(implementation.code.length > 0, "implementation missing");
    }

    // ── config/cap-v2.json ────────────────────────────────────────────────────

    /// @dev Like {InfraSerializer-_saveInfra}, but the reserve token is the mock this script
    /// deployed, so it is written rather than preserved, and the testnet tokens are recorded too.
    function _saveSepolia(
        ImplementationsConfig memory implems,
        InfraConfig memory _infra,
        address wallet,
        address[7] memory tokens
    ) private {
        string memory path = string.concat(vm.projectRoot(), "/config/cap-v2.json");

        string memory implemsJson = "implems";
        vm.serializeAddress(implemsJson, "stablecoin", implems.stablecoin);
        vm.serializeAddress(implemsJson, "irm", implems.irm);
        vm.serializeAddress(implemsJson, "oracle", implems.oracle);
        vm.serializeAddress(implemsJson, "registry", implems.registry);
        vm.serializeAddress(implemsJson, "floatingMarket", implems.floatingMarket);
        vm.serializeAddress(implemsJson, "fixedMarket", implems.fixedMarket);
        vm.serializeAddress(implemsJson, "tranche", implems.tranche);
        vm.serializeAddress(implemsJson, "underwriter", implems.underwriter);
        implemsJson = vm.serializeAddress(implemsJson, "wrapper", implems.wrapper);

        string memory infraJson = "infra";
        vm.serializeAddress(infraJson, "accessManager", _infra.accessManager);
        vm.serializeAddress(infraJson, "stablecoin", _infra.stablecoin);
        vm.serializeAddress(infraJson, "irm", _infra.irm);
        vm.serializeAddress(infraJson, "oracle", _infra.oracle);
        vm.serializeAddress(infraJson, "chainlinkAdapter", _infra.chainlinkAdapter);
        vm.serializeAddress(infraJson, "registry", _infra.registry);
        vm.serializeAddress(infraJson, "factory", _infra.factory);
        vm.serializeAddress(infraJson, "floatingMarketBeacon", _infra.floatingMarketBeacon);
        vm.serializeAddress(infraJson, "fixedMarketBeacon", _infra.fixedMarketBeacon);
        vm.serializeAddress(infraJson, "trancheBeacon", _infra.trancheBeacon);
        vm.serializeAddress(infraJson, "underwriterBeacon", _infra.underwriterBeacon);
        infraJson = vm.serializeAddress(infraJson, "wrapper", _infra.wrapper);

        string memory testnetJson = "testnet";
        vm.serializeAddress(testnetJson, "mUSDC", tokens[0]);
        vm.serializeAddress(testnetJson, "mWETH", tokens[1]);
        vm.serializeAddress(testnetJson, "mWBTC", tokens[2]);
        vm.serializeAddress(testnetJson, "mwstETH", tokens[3]);
        vm.serializeAddress(testnetJson, "wstethFeed", tokens[4]);
        vm.serializeAddress(testnetJson, "ethFallbackFeed", tokens[5]);
        vm.serializeAddress(testnetJson, "btcFallbackFeed", tokens[6]);
        vm.serializeAddress(testnetJson, "ethUsdFeed", ETH_USD);
        testnetJson = vm.serializeAddress(testnetJson, "btcUsdFeed", BTC_USD);

        string memory chainJson = "chain";
        vm.serializeAddress(chainJson, "deployer", wallet);
        vm.serializeAddress(chainJson, "timelock", address(0));
        vm.serializeAddress(chainJson, "multisig", address(0));
        vm.serializeAddress(chainJson, "stablecoinUnderlying", tokens[0]);
        vm.serializeAddress(chainJson, "reserveVault", address(0));
        vm.serializeString(chainJson, "implems", implemsJson);
        vm.serializeString(chainJson, "infra", infraJson);
        chainJson = vm.serializeString(chainJson, "testnet", testnetJson);

        string memory previous = vm.exists(path) ? vm.readFile(path) : "{}";
        string memory merged = "merged";
        vm.serializeJson(merged, previous);
        merged = vm.serializeString(merged, Strings.toString(block.chainid), chainJson);
        vm.writeFile(path, merged);
    }

    // ── config/sepolia-scenarios.json ─────────────────────────────────────────

    /// @dev Everything the UI team needs to find the storyline: actors, groups, markets, pools.
    function _writeManifest() private {
        string memory path = string.concat(vm.projectRoot(), "/config/sepolia-scenarios.json");

        string memory actorsJson = "actors";
        string memory actorsOut;
        for (uint256 i; i < allActors.length; ++i) {
            actorsOut = vm.serializeAddress(actorsJson, allActors[i].label, allActors[i].addr);
        }
        actorsJson = actorsOut;

        string memory tokensJson = "tokens";
        vm.serializeAddress(tokensJson, "mUSDC", address(mUsdc));
        vm.serializeAddress(tokensJson, "mWETH", address(mWeth));
        vm.serializeAddress(tokensJson, "mWBTC", address(mWbtc));
        vm.serializeAddress(tokensJson, "mwstETH", address(mWsteth));
        vm.serializeAddress(tokensJson, "wstethFeed", address(wstethFeed));
        vm.serializeAddress(tokensJson, "ethFallbackFeed", address(ethFallbackFeed));
        tokensJson = vm.serializeAddress(tokensJson, "btcFallbackFeed", address(btcFallbackFeed));

        string memory rolesJson = "roles";
        vm.serializeUint(rolesJson, "atlasOwners", atlasOwners);
        vm.serializeUint(rolesJson, "borealOwners", borealOwners);
        vm.serializeUint(rolesJson, "cinderOwners", cinderOwners);
        vm.serializeUint(rolesJson, "curatorA", curatorRoles[0]);
        vm.serializeUint(rolesJson, "curatorB", curatorRoles[1]);
        vm.serializeUint(rolesJson, "curatorC", curatorRoles[2]);
        vm.serializeUint(rolesJson, "atlasBorrowersA", atlasBorrowersA);
        vm.serializeUint(rolesJson, "atlasBorrowersB", atlasBorrowersB);
        vm.serializeUint(rolesJson, "borealBorrowersA", borealBorrowersA);
        vm.serializeUint(rolesJson, "borealBorrowersB", borealBorrowersB);
        vm.serializeUint(rolesJson, "cinderBtcBorrowers", cinderBtcBorrowers);
        vm.serializeUint(rolesJson, "cinderWstethBorrowersA", cinderWstethBorrowersA);
        vm.serializeUint(rolesJson, "cinderWstethBorrowersB", cinderWstethBorrowersB);
        vm.serializeUint(rolesJson, "atlasLpsV1", atlasLpsV1);
        vm.serializeUint(rolesJson, "atlasLpsV2", atlasLpsV2);
        vm.serializeUint(rolesJson, "uwWethAllocators", uwWethAllocators);
        vm.serializeUint(rolesJson, "uwWethDepositors", uwWethDepositors);
        vm.serializeUint(rolesJson, "uwWbtcAllocators", uwWbtcAllocators);
        vm.serializeUint(rolesJson, "uwWstethAllocatorsV1", uwWstethAllocatorsV1);
        vm.serializeUint(rolesJson, "uwWstethAllocatorsV2", uwWstethAllocatorsV2);
        rolesJson = vm.serializeUint(rolesJson, "uwWstethDepositors", uwWstethDepositors);

        string memory marketsJson = "markets";
        vm.serializeString(
            marketsJson, "atlasEthCredit", _marketJson("atlasEthCredit", atlas, "floating", atlasTranches)
        );
        vm.serializeString(
            marketsJson, "borealFixedTerm", _marketJson("borealFixedTerm", boreal, "fixed", borealTranches)
        );
        vm.serializeString(
            marketsJson, "cinderBtcCredit", _marketJson("cinderBtcCredit", cinderBtc, "floating", cinderBtcTranches)
        );
        marketsJson = vm.serializeString(
            marketsJson,
            "cinderWstethCredit",
            _marketJson("cinderWstethCredit", cinderWsteth, "floating", cinderWstethTranches)
        );

        string memory poolsJson = "underwriters";
        vm.serializeAddress(poolsJson, "capWethUnderwriter", uwWeth);
        vm.serializeAddress(poolsJson, "capWbtcUnderwriter", uwWbtc);
        poolsJson = vm.serializeAddress(poolsJson, "capWstethUnderwriter", uwWsteth);

        string memory root = "manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeBytes32(root, "namespace", namespace);
        vm.serializeUint(root, "actorsIndexOffset", indexOffset);
        vm.serializeAddress(root, "atlasRetiredTranche", atlasRetiredTranche);
        vm.serializeString(root, "actors", actorsJson);
        vm.serializeString(root, "tokens", tokensJson);
        vm.serializeString(root, "roles", rolesJson);
        vm.serializeString(root, "markets", marketsJson);
        root = vm.serializeString(root, "underwriters", poolsJson);
        vm.writeFile(path, root);
        console.log("Wrote", path);
    }

    function _marketJson(string memory key, address market, string memory kind, address[] memory tranches)
        private
        returns (string memory json)
    {
        string memory obj = string.concat("market.", key);
        vm.serializeAddress(obj, "address", market);
        vm.serializeString(obj, "kind", kind);
        vm.serializeUint(obj, "ownerRole", registry.marketOwnerRole(market));
        json = vm.serializeAddress(obj, "tranches", tranches);
    }

    function _print(InfraConfig memory _infra, address wallet, bytes32 ns) private view {
        console.log("");
        console.log("Sepolia chain ID", block.chainid);
        console.log("Deployer/admin", wallet);
        console.log("Salt namespace");
        console.logBytes32(ns);
        console.log("accessManager", _infra.accessManager);
        console.log("registry     ", _infra.registry);
        console.log("stablecoin   ", _infra.stablecoin);
        console.log("wrapper      ", _infra.wrapper);
        console.log("oracle       ", _infra.oracle);
        console.log("adapter      ", _infra.chainlinkAdapter);
        console.log("irm          ", _infra.irm);
        console.log("factory      ", _infra.factory);
        console.log("mUSDC        ", address(mUsdc));
        console.log("mWETH        ", address(mWeth));
        console.log("mWBTC        ", address(mWbtc));
        console.log("mwstETH       ", address(mWsteth));
    }
}
