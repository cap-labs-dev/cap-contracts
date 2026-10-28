// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { IVaultV1 } from "../../contracts/migration/IVaultV1.sol";
import { Migrator } from "../../contracts/migration/Migrator.sol";
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

/// @dev The v1 vault's record of the underlying supplied, which the unwind brings back to the proxy
interface IVaultV1Supplies {
    function totalSupplies(address asset) external view returns (uint256 supplied);
}

/// @dev The v1 FeeReceiver setter the runbook uses to send fee proceeds to the migrator
interface IFeeReceiverV1Admin {
    function setStakedCapToken(address stakedCapToken) external;
}

/// @dev The v1 stcUSD vesting surface the rehearsal settles before upgrading
interface IStakedCapV1Vesting {
    function notify() external;
    function lockedProfit() external view returns (uint256 locked);
    function lastNotify() external view returns (uint256 timestamp);
    function lockDuration() external view returns (uint256 duration);
    function totalAssets() external view returns (uint256 total);
}

/// @title MigrationBase
/// @notice Fork Ethereum, upgrade the live cUSD and stcUSD proxies, and stand the v2 stack up
///         next to them.
///
/// The rehearsal follows the {Migrator} runbook. The fork is mid-unwind, so
/// {_assumeUnwindComplete} stands in for that step by topping cUSD up to par USDC; the migrator
/// checks the backing itself and refuses to finish without it.
abstract contract MigrationBase is Test, DeployImplems, DeployInfra, MigrateInfra, ConfigureAccessControl {
    using stdJson for string;

    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // keccak256(abi.encode(uint256(keccak256("cap.storage.Access")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V1_ACCESS_STORAGE = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;
    bytes32 internal constant MIGRATION_SALT = keccak256("migration-fork");
    /// @dev Cap on the executor's top-up; the gap was about 392 USDC at block 26,285,413
    uint256 internal constant MAX_TOP_UP = 10_000e6;

    UsersConfig internal users;
    Migrator internal migrator;
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
    /// @dev v1 cUSD FeeReceiver, which the runbook points at the migrator
    address internal constant FEE_RECEIVER = 0x0036c7b9b62c53F47c804a5643F0c09f864beF0b;
    /// @dev cUSD OFT lockbox
    address internal constant CUSD_OFT_LOCKBOX = 0xA62571EbdFfAbC3051a2e5B9e1f57b23D830c8Fd;

    function setUp() public {
        if (!_tryForkEthereum()) return;

        _loadLiveConfig();
        _snapshotLive();
        _deployAndUpgrade();
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
        require(FEE_RECEIVER.code.length > 0, "v1 FeeReceiver missing on this fork");

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

        migrator = _deployMigrator(implems, infra, users, FEE_RECEIVER, address(this));

        _redirectV1Fees(address(migrator));
        _assumeUnwindComplete();
        _settleV1Vesting();
        _authorizeV1(bytes4(0), address(scoin), address(migrator));
        _authorizeV1(bytes4(0), address(wrapper), address(migrator));
        // the v2 roles are in place first, so the migrator can confirm the tokens stay upgradable
        _initInfraAccessControl(infra, users);
        uint256 sharePrice = wrapper.convertToAssets(1e18);
        uint256 stakedAssets = wrapper.totalAssets();
        // the executor covers the gap v1's oracle-priced mints left between supply and USDC
        deal(address(usdc), address(this), MAX_TOP_UP);
        usdc.approve(address(migrator), MAX_TOP_UP);
        migrator.migrate(MAX_TOP_UP);
        vm.clearMockedCalls();
        assertEq(wrapper.convertToAssets(1e18), sharePrice, "stcUSD share price is continuous");
        assertEq(wrapper.totalAssets(), stakedAssets, "stcUSD assets are continuous");

        assertEq(infra.stablecoin, address(scoin), "cUSD address must not move");
        assertEq(infra.wrapper, address(wrapper), "stcUSD address must not move");
    }

    /// @dev Loans repaid and fractional reserve divested with its interest realized: every USDC v1
    ///      records as supplied is back on the proxy. That is still short of the supply; the executor
    ///      tops up the rest. The fork is mid-unwind, so v1's own records of it are stood in for until
    ///      the upgrade replaces them.
    function _assumeUnwindComplete() internal {
        uint256 supplied = IVaultV1Supplies(address(scoin)).totalSupplies(address(usdc));
        if (usdc.balanceOf(address(scoin)) < supplied) deal(address(usdc), address(scoin), supplied);
        vm.mockCall(address(scoin), abi.encodeCall(IVaultV1.totalBorrows, (address(usdc))), abi.encode(0));
        vm.mockCall(address(scoin), abi.encodeCall(IVaultV1.loaned, (address(usdc))), abi.encode(0));
        vm.mockCall(address(scoin), abi.encodeCall(IVaultV1.claimableInterest, (address(usdc))), abi.encode(0));
    }

    /// @dev The runbook step the migration enforces: let a running release finish, notify any
    ///      un-notified balance, and let that release finish too.
    function _settleV1Vesting() internal {
        IStakedCapV1Vesting stakedV1 = IStakedCapV1Vesting(address(wrapper));
        uint256 duration = stakedV1.lockDuration();
        if (stakedV1.lockedProfit() > 0) vm.warp(stakedV1.lastNotify() + duration);
        if (scoin.balanceOf(address(wrapper)) > stakedV1.totalAssets()) {
            stakedV1.notify();
            vm.warp(block.timestamp + duration);
        }
    }

    /// @dev Runbook step 1: fee proceeds collect in the migrator rather than vesting into stcUSD
    function _redirectV1Fees(address to) internal {
        _authorizeV1(IFeeReceiverV1Admin.setStakedCapToken.selector, FEE_RECEIVER, address(this));
        IFeeReceiverV1Admin(FEE_RECEIVER).setStakedCapToken(to);
    }

    /// @dev Grant `account` a v1 permission, as the v1 admin would
    function _authorizeV1(bytes4 selector, address target, address account) internal {
        address accessControl = _v1AccessControl(target);
        require(accessControl.code.length > 0, "v1 AccessControl missing");

        IAccessControlV1 ac = IAccessControlV1(accessControl);
        bytes32 grantedRole = ac.role(selector, target);
        uint256 holders = ac.getRoleMemberCount(grantedRole);
        for (uint256 i; i < holders; ++i) {
            if (ac.getRoleMember(grantedRole, i) == account) return;
        }

        address admin = ac.getRoleMember(bytes32(0), 0);
        vm.prank(admin);
        ac.grantAccess(selector, target, account);
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
