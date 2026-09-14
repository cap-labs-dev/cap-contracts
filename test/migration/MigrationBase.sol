// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../../script/deploy/interfaces/DeployConfigs.sol";
import { ConfigureAccessControl } from "../../script/deploy/service/ConfigureAccessControl.sol";
import { DeployImplems } from "../../script/deploy/service/DeployImplems.sol";
import { DeployInfra } from "../../script/deploy/service/DeployInfra.sol";
import { MigrateInfra } from "../../script/deploy/service/MigrateInfra.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

/// @dev v1 AccessControl on the live cUSD / stcUSD proxies
interface IAccessControlV1 {
    function grantAccess(bytes4 selector, address target, address account) external;
    function role(bytes4 selector, address target) external view returns (bytes32);
    function getRoleMember(bytes32 roleId, uint256 index) external view returns (address);
    function getRoleMemberCount(bytes32 roleId) external view returns (uint256);
}

/// @title MigrationBase
/// @notice Fork Ethereum, upgrade the live cUSD and stcUSD proxies, and stand the v2 stack up
///         next to them.
///
/// The rehearsal world is the one after the v1 unwind: every loan repaid to cUSD, the
/// fractional reserve idle, and wWTGXX swapped for USDC. {_assumeUnwindComplete} tops the
/// vault up to par USDC so the post-upgrade reserve matches that state.
abstract contract MigrationBase is Test, DeployImplems, DeployInfra, MigrateInfra, ConfigureAccessControl {
    using stdJson for string;

    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // keccak256(abi.encode(uint256(keccak256("cap.storage.Access")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V1_ACCESS_STORAGE = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;
    bytes32 internal constant MIGRATION_SALT = keccak256("migration-fork");

    UsersConfig internal users;
    ImplementationsConfig internal implems;
    InfraConfig internal infra;

    Stablecoin internal scoin;
    Wrapper internal wrapper;
    IERC20 internal usdc;

    address internal governor;
    address internal keeper;
    address internal guardian;
    address internal liquidator;
    address internal alice;
    address internal stranger;

    string internal liveName;
    string internal liveSymbol;
    string internal liveWrapperName;
    string internal liveWrapperSymbol;

    struct LiveSnapshot {
        uint256 cusdSupply;
        uint256 stakedSupply;
        uint256 wrapperCusd;
        uint256 lockboxCusd;
        uint256 lockboxStaked;
        uint8 cusdDecimals;
        uint8 wrapperDecimals;
        bytes32 cusdDomain;
        bytes32 wrapperDomain;
        address cusdImpl;
        address wrapperImpl;
    }

    LiveSnapshot internal live;

    /// @dev stcUSD OFT lockbox, a known live holder used as a balance canary
    address internal constant STCUSD_OFT_LOCKBOX = 0x983AEAaA0d0426839158435C43725EA7F45d4137;
    /// @dev cUSD OFT lockbox
    address internal constant CUSD_OFT_LOCKBOX = 0xA62571EbdFfAbC3051a2e5B9e1f57b23D830c8Fd;

    function setUp() public {
        if (!_tryForkEthereum()) return;

        _loadLiveConfig();
        _snapshotLive();
        _deployAndUpgrade();
        _assumeUnwindComplete();
    }

    /// @dev Fork mainnet. Skips the suite when `ETH_RPC_URL` is unset so CI without an RPC stays green.
    function _tryForkEthereum() internal returns (bool forked) {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            try vm.rpcUrl("ethereum") returns (string memory named) {
                url = named;
            } catch { }
        }
        if (bytes(url).length == 0 || keccak256(bytes(url)) == keccak256(bytes("${ETH_RPC_URL}"))) {
            vm.skip(true, "ETH_RPC_URL unset");
            return false;
        }
        vm.createSelectFork(url);
        forked = true;
    }

    function _loadLiveConfig() internal {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/config/cap-v2.json"));
        address liveCusd = json.readAddress("$['1'].infra.stablecoin");
        address liveWrapper = json.readAddress("$['1'].infra.wrapper");
        address liveUsdc = json.readAddress("$['1'].stablecoinUnderlying");

        require(liveCusd.code.length > 0, "cUSD missing on this fork");
        require(liveWrapper.code.length > 0, "stcUSD missing on this fork");
        require(liveUsdc.code.length > 0, "USDC missing on this fork");

        scoin = Stablecoin(liveCusd);
        wrapper = Wrapper(liveWrapper);
        usdc = IERC20(liveUsdc);

        governor = makeAddr("governor");
        keeper = makeAddr("keeper");
        guardian = makeAddr("guardian");
        liquidator = makeAddr("liquidator");
        alice = makeAddr("alice");
        stranger = makeAddr("stranger");

        users = UsersConfig({
            deployer: address(this),
            governor: governor,
            keeper: keeper,
            guardian: guardian,
            admin: address(this),
            liquidator: liquidator,
            stablecoinUnderlying: liveUsdc,
            reserveVault: address(0)
        });
    }

    function _snapshotLive() internal {
        liveName = IERC20Metadata(address(scoin)).name();
        liveSymbol = IERC20Metadata(address(scoin)).symbol();
        liveWrapperName = IERC20Metadata(address(wrapper)).name();
        liveWrapperSymbol = IERC20Metadata(address(wrapper)).symbol();

        live.cusdSupply = IERC20(address(scoin)).totalSupply();
        live.stakedSupply = IERC20(address(wrapper)).totalSupply();
        live.wrapperCusd = IERC20(address(scoin)).balanceOf(address(wrapper));
        live.lockboxCusd = IERC20(address(scoin)).balanceOf(CUSD_OFT_LOCKBOX);
        live.lockboxStaked = IERC20(address(wrapper)).balanceOf(STCUSD_OFT_LOCKBOX);
        live.cusdDecimals = IERC20Metadata(address(scoin)).decimals();
        live.wrapperDecimals = IERC20Metadata(address(wrapper)).decimals();
        live.cusdDomain = IERC20Permit(address(scoin)).DOMAIN_SEPARATOR();
        live.wrapperDomain = IERC20Permit(address(wrapper)).DOMAIN_SEPARATOR();
        live.cusdImpl = _implementation(address(scoin));
        live.wrapperImpl = _implementation(address(wrapper));
    }

    function _deployAndUpgrade() internal {
        implems = _deployImplementations();
        infra = _deployInfraAroundExisting(implems, users, MIGRATION_SALT, address(scoin), address(wrapper));

        _authorizeV1Upgrade(address(scoin));
        _authorizeV1Upgrade(address(wrapper));
        _upgradeExistingTokens(implems, infra, users, liveName, liveSymbol);

        _initInfraAccessControl(infra, users);

        assertEq(infra.stablecoin, address(scoin), "cUSD address must not move");
        assertEq(infra.wrapper, address(wrapper), "stcUSD address must not move");
    }

    /// @dev Loans repaid, fractional reserve divested, wWTGXX swapped to USDC: the vault holds
    ///      par USDC for the outstanding supply. Deal the shortfall if this fork is still mid-unwind.
    function _assumeUnwindComplete() internal {
        uint256 needed = scoin.previewMint(scoin.totalSupply());
        uint256 held = usdc.balanceOf(address(scoin));
        if (held < needed) deal(address(usdc), address(scoin), needed);
    }

    function _authorizeV1Upgrade(address proxy) internal {
        address accessControl = _v1AccessControl(proxy);
        require(accessControl.code.length > 0, "v1 AccessControl missing");

        IAccessControlV1 ac = IAccessControlV1(accessControl);
        bytes32 upgradeRole = ac.role(bytes4(0), proxy);
        uint256 holders = ac.getRoleMemberCount(upgradeRole);
        for (uint256 i; i < holders; ++i) {
            if (ac.getRoleMember(upgradeRole, i) == address(this)) return;
        }

        address admin = ac.getRoleMember(bytes32(0), 0);
        vm.prank(admin);
        ac.grantAccess(bytes4(0), proxy, address(this));
    }

    function _v1AccessControl(address proxy) internal view returns (address accessControl) {
        accessControl = address(uint160(uint256(vm.load(proxy, V1_ACCESS_STORAGE))));
    }

    function _implementation(address proxy) internal view returns (address impl) {
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _fundAlice(uint256 usdcAmount) internal {
        deal(address(usdc), alice, usdcAmount);
        vm.prank(alice);
        usdc.approve(address(scoin), type(uint256).max);
    }
}
