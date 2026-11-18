// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BeaconFactory } from "../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { Oracle } from "../../contracts/cap/oracle/Oracle.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { TestnetERC20 } from "../../contracts/testnet/TestnetERC20.sol";
import { TestnetPriceFeed } from "../../contracts/testnet/TestnetPriceFeed.sol";
import { InfraSerializer } from "../config/InfraSerializer.sol";
import { ImplementationsConfig, InfraConfig } from "../deploy/interfaces/DeployConfigs.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

/// @title VerifyArgs
/// @notice Print the constructor arguments of every Sepolia contract that Forge could not verify
/// during the broadcast: the ones created inside other calls (CreateX, the beacon factory).
/// @dev `forge script --verify` only submits contracts the script created directly. This script
/// reads `config/cap-v2.json` and `config/sepolia-scenarios.json`, rebuilds each remaining contract's
/// constructor arguments from the same values the deployment used, checks the immutable-bearing ones
/// by redeploying locally and comparing runtime code, and prints one `VERIFY <address> <path:Name>
/// <args>` line per contract for `script/sepolia/verify-sepolia.sh` to feed to `forge verify-contract`.
/// Read-only; run with `--rpc-url sepolia`.
contract VerifyArgs is Script, InfraSerializer {
    using stdJson for string;

    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant DEFAULT_VESTING = 12 hours;
    uint256 private constant FIXED_MAX_TERM_AT_CREATION = 30 days;

    string private constant OZ = "node_modules/@openzeppelin/contracts/";

    InfraConfig private infra;
    string private manifest;
    uint256 private mismatches;

    function run() external {
        require(block.chainid == 11155111, "Sepolia only");
        (, infra) = _readInfra();
        manifest = vm.readFile(string.concat(vm.projectRoot(), "/config/sepolia-scenarios.json"));
        address deployer = _readDeployer();
        require(deployer != address(0), "run save() first");

        _tokensAndFeeds(deployer);
        _accessManagerAndAdapter(deployer);
        _infraProxies();
        _beacons();
        _markets();
        _pools();

        console.log("");
        console.log("code mismatches", mismatches);
        require(mismatches == 0, "constructor arguments do not reproduce the on-chain code");
    }

    // ── testnet tokens and feeds ──────────────────────────────────────────────

    function _tokensAndFeeds(address deployer) private {
        string[4] memory keys = ["mUSDC", "mWETH", "mWBTC", "mwstETH"];
        for (uint256 i; i < 4; ++i) {
            address token = _testnet(keys[i]);
            bytes memory args = abi.encode(
                IERC20Metadata(token).name(), IERC20Metadata(token).symbol(), IERC20Metadata(token).decimals(), deployer
            );
            _check(token, abi.encodePacked(type(TestnetERC20).creationCode, args));
            _emit(token, "contracts/testnet/TestnetERC20.sol:TestnetERC20", args);
        }
        string[3] memory feeds = ["wstethFeed", "ethFallbackFeed", "btcFallbackFeed"];
        for (uint256 i; i < 3; ++i) {
            address feed = _testnet(feeds[i]);
            // none of the three has been moved since deployment, so the live answer is the initial one
            bytes memory args =
                abi.encode(deployer, TestnetPriceFeed(feed).description(), TestnetPriceFeed(feed).answer());
            _check(feed, abi.encodePacked(type(TestnetPriceFeed).creationCode, args));
            _emit(feed, "contracts/testnet/TestnetPriceFeed.sol:TestnetPriceFeed", args);
        }
    }

    // ── access manager and the adapter library ────────────────────────────────

    function _accessManagerAndAdapter(address deployer) private {
        bytes memory args = abi.encode(deployer);
        _check(infra.accessManager, abi.encodePacked(type(AccessManager).creationCode, args));
        _emit(infra.accessManager, string.concat(OZ, "access/manager/AccessManager.sol:AccessManager"), args);
        _emit(infra.chainlinkAdapter, "contracts/cap/oracle/ChainlinkAdapter.sol:ChainlinkAdapter", "");
    }

    // ── UUPS proxies ──────────────────────────────────────────────────────────

    function _infraProxies() private {
        string memory proxyPath = string.concat(OZ, "proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");

        _proxy(
            proxyPath,
            infra.irm,
            abi.encodeCall(
                InterestRateModel.initialize,
                (infra.accessManager, infra.stablecoin, 1e27, 2e27, 1e27, 0.02e27, 1 hours, 0.8e27, 0.1e27, 1.25e27)
            )
        );
        _proxy(
            proxyPath,
            infra.stablecoin,
            abi.encodeCall(
                Stablecoin.initialize,
                (infra.accessManager, _testnet("mUSDC"), "Cap USD", "cUSD", infra.irm, address(0), DEFAULT_VESTING)
            )
        );
        _proxy(proxyPath, infra.wrapper, abi.encodeCall(Wrapper.initialize, (infra.accessManager, infra.stablecoin)));
        _proxy(proxyPath, infra.oracle, abi.encodeCall(Oracle.initialize, (infra.accessManager)));
        _proxy(proxyPath, infra.factory, abi.encodeCall(BeaconFactory.initialize, (infra.accessManager)));
        _proxy(
            proxyPath,
            infra.registry,
            abi.encodeCall(
                Registry.initialize,
                (
                    infra.accessManager,
                    IRegistry.InitParams({
                        stablecoin: infra.stablecoin,
                        oracle: infra.oracle,
                        irm: infra.irm,
                        factory: infra.factory,
                        floatingMarketBeacon: infra.floatingMarketBeacon,
                        fixedMarketBeacon: infra.fixedMarketBeacon,
                        trancheBeacon: infra.trancheBeacon,
                        underwriterBeacon: infra.underwriterBeacon,
                        wrapper: infra.wrapper
                    })
                )
            )
        );
    }

    function _proxy(string memory path, address proxy, bytes memory initData) private {
        address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(implementation.code.length > 0, "implementation missing");
        bytes memory args = abi.encode(implementation, initData);
        // the initializer would run again on a local redeploy, so the check deploys with a harmless
        // view call instead (the proxy refuses empty data); the runtime code is the same either way,
        // ERC1967Proxy has no immutables
        _checkRuntime(
            proxy,
            abi.encodePacked(
                type(ERC1967Proxy).creationCode, abi.encode(implementation, abi.encodeWithSignature("authority()"))
            )
        );
        _emit(proxy, path, args);
    }

    // ── beacons ───────────────────────────────────────────────────────────────

    function _beacons() private {
        string memory path = string.concat(OZ, "proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon");
        address[4] memory beacons =
            [infra.floatingMarketBeacon, infra.fixedMarketBeacon, infra.trancheBeacon, infra.underwriterBeacon];
        for (uint256 i; i < 4; ++i) {
            bytes memory args = abi.encode(UpgradeableBeacon(beacons[i]).implementation(), infra.accessManager);
            _check(beacons[i], abi.encodePacked(type(UpgradeableBeacon).creationCode, args));
            _emit(beacons[i], path, args);
        }
    }

    // ── markets and tranches ──────────────────────────────────────────────────

    function _markets() private {
        string[4] memory keys = ["atlasEthCredit", "borealFixedTerm", "cinderBtcCredit", "cinderWstethCredit"];
        address retired = manifest.readAddress(".atlasRetiredTranche");
        for (uint256 i; i < 4; ++i) {
            string memory prefix = string.concat(".markets.", keys[i]);
            address market = manifest.readAddress(string.concat(prefix, ".address"));
            bool fixedMarket =
                keccak256(bytes(manifest.readString(string.concat(prefix, ".kind")))) == keccak256("fixed");
            string memory name = IBaseMarket(market).name();

            bytes memory init = fixedMarket
                ? abi.encodeCall(
                    FixedMarket.initialize,
                    (infra.accessManager, infra.registry, name, FIXED_MAX_TERM_AT_CREATION, 1 days, 1 days)
                )
                : abi.encodeCall(FloatingMarket.initialize, (infra.accessManager, infra.registry, name));
            _beaconProxy(market, fixedMarket ? infra.fixedMarketBeacon : infra.floatingMarketBeacon, init);

            // tranches were created with the market's vesting default; Atlas's retired fifth tranche
            // was the one exception (6 hours), its fourth took the 12 hour default
            uint256 vesting = fixedMarket ? FIXED_MAX_TERM_AT_CREATION / 2 : DEFAULT_VESTING;
            address[] memory tranches = manifest.readAddressArray(string.concat(prefix, ".tranches"));
            for (uint256 j; j < tranches.length; ++j) {
                _tranche(tranches[j], market, vesting);
            }
            if (i == 0) _tranche(retired, market, 6 hours);
        }
    }

    function _tranche(address tranche, address market, uint256 vesting) private {
        bytes memory init = abi.encodeCall(
            ITranche.initialize,
            (
                infra.accessManager,
                infra.registry,
                IERC4626(tranche).asset(),
                IERC20Metadata(tranche).name(),
                IERC20Metadata(tranche).symbol(),
                market,
                infra.oracle,
                vesting
            )
        );
        _beaconProxy(tranche, infra.trancheBeacon, init);
    }

    // ── underwriter pools ─────────────────────────────────────────────────────

    function _pools() private {
        string[3] memory keys = ["capWethUnderwriter", "capWbtcUnderwriter", "capWstethUnderwriter"];
        for (uint256 i; i < 3; ++i) {
            address pool = manifest.readAddress(string.concat(".underwriters.", keys[i]));
            bytes memory init = abi.encodeCall(
                IUnderwriter.initialize,
                (
                    infra.accessManager,
                    infra.registry,
                    IERC20Metadata(pool).name(),
                    IERC20Metadata(pool).symbol(),
                    IERC4626(pool).asset(),
                    infra.stablecoin,
                    DEFAULT_VESTING
                )
            );
            _beaconProxy(pool, infra.underwriterBeacon, init);
        }
    }

    function _beaconProxy(address proxy, address beacon, bytes memory initData) private {
        bytes memory args = abi.encode(beacon, initData);
        // the initializer would run again on a local redeploy, so only the beacon immutable is
        // checked here, through the runtime code it is baked into
        _checkRuntime(proxy, abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
        _emit(proxy, string.concat(OZ, "proxy/beacon/BeaconProxy.sol:BeaconProxy"), args);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Redeploy locally from `initCode` and require the same runtime code as `deployed`
    function _check(address deployed, bytes memory initCode) private {
        _checkRuntime(deployed, initCode);
    }

    function _checkRuntime(address deployed, bytes memory initCode) private {
        address local;
        assembly {
            local := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (local == address(0) || keccak256(local.code) != keccak256(deployed.code)) {
            console.log("!! runtime code mismatch for", deployed);
            mismatches++;
        }
    }

    function _emit(address target, string memory contractPath, bytes memory args) private pure {
        console.log(string.concat("VERIFY ", vm.toString(target), " ", contractPath, " ", vm.toString(args)));
    }

    function _testnet(string memory key) private view returns (address) {
        return vm.readFile(string.concat(vm.projectRoot(), "/config/cap-v2.json"))
            .readAddress(string.concat("$['", vm.toString(block.chainid), "'].testnet.", key));
    }
}
