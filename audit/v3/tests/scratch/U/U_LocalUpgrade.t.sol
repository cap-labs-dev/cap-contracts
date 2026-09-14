// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Workstream U - offline PoC (no RPC). Deploys the v1 `CapToken` and `StakedCap` implementations
// from bytecode compiled out of the v1 worktree (main @ 695c828, solc 0.8.28, OZ 5.4.0) behind
// fresh ERC1967 proxies, initialises them exactly as v1 did, gives them supply and reserves, then
// upgrades to the HEAD `Stablecoin` / `Wrapper` implementations the way the live timelock would.
//
// Run: FOUNDRY_TEST=audit/v3/tests/scratch/U forge test --match-path 'audit/v3/tests/scratch/U/U_Local*' -vv
// test_FAIL_* assert the intended post-upgrade behaviour and therefore fail on current code.

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { IPremiumVesting } from "../../../../../contracts/interfaces/IPremiumVesting.sol";
import { V1Artifacts } from "./V1Artifacts.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

/// @dev Stand-in for the v1 `AccessControl` proxy: the deployer holds every role.
contract MockV1AccessControl {
    address public immutable admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function checkAccess(bytes4, address, address caller) external view returns (bool) {
        require(caller == admin, "v1 AccessDenied");
        return true;
    }
}

contract Usdc6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IV1CapToken {
    function initialize(
        string memory _name,
        string memory _symbol,
        address _accessControl,
        address _feeAuction,
        address _oracle,
        address[] calldata _assets,
        address _insuranceFund
    ) external;
    function paused() external view returns (bool);
    function nonces(address) external view returns (uint256);
}

interface IV1StakedCap {
    function initialize(address _accessControl, address _asset, uint256 _lockDuration) external;
    function notify() external;
    function lockedProfit() external view returns (uint256);
}

contract U_LocalUpgrade is Test {
    bytes32 constant SLOT_ERC20 = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
    bytes32 constant SLOT_INIT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant SLOT_ERC4626 = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
    bytes32 constant SLOT_ACCESS_MANAGED = 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00;
    bytes32 constant SLOT_V1_ACCESS = 0xb413d65cb88f23816c329284a0d3eb15a99df7963ab7402ade4c5da22bff6b00;

    Usdc6 usdc;
    MockV1AccessControl ac;
    address v1CapTokenImpl;
    address v1StakedCapImpl;
    address cusdAddr;
    address stcusdAddr;
    address stablecoinImpl;
    address wrapperImpl;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SUPPLY = 84_884_291e18;
    uint256 constant ON_HAND_USDC = 3_219e6;

    function _deploy(bytes memory creation) internal returns (address addr) {
        assembly {
            addr := create(0, add(creation, 0x20), mload(creation))
        }
        require(addr != address(0), "create failed");
    }

    function setUp() public {
        usdc = new Usdc6();
        ac = new MockV1AccessControl(address(this));
        vm.etch(V1Artifacts.VAULTLOGIC_ADDR, _deploy(V1Artifacts.vault_logic()).code);
        vm.etch(V1Artifacts.MINTERLOGIC_ADDR, _deploy(V1Artifacts.minter_logic()).code);
        vm.etch(V1Artifacts.FRACTIONALRESERVELOGIC_ADDR, _deploy(V1Artifacts.fractional_reserve_logic()).code);
        v1CapTokenImpl = _deploy(V1Artifacts.cap_token());
        v1StakedCapImpl = _deploy(V1Artifacts.staked_cap());

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        cusdAddr = address(
            new ERC1967Proxy(
                v1CapTokenImpl,
                abi.encodeCall(
                    IV1CapToken.initialize,
                    (
                        "cap USD",
                        "cUSD",
                        address(ac),
                        makeAddr("feeAuction"),
                        makeAddr("oracle"),
                        assets,
                        makeAddr("insurance")
                    )
                )
            )
        );
        stcusdAddr = address(
            new ERC1967Proxy(v1StakedCapImpl, abi.encodeCall(IV1StakedCap.initialize, (address(ac), cusdAddr, 1 days)))
        );

        // supply and balances as v1 minting would have left them (written straight into the OZ ERC20 namespace)
        vm.store(cusdAddr, bytes32(uint256(SLOT_ERC20) + 2), bytes32(SUPPLY));
        _setBal(alice, 10_000e18);
        _setBal(bob, 10_000e18);
        _setBal(makeAddr("rest"), SUPPLY - 20_000e18);
        usdc.mint(cusdAddr, ON_HAND_USDC);

        // stake and vest some yield in the v1 StakedCap so lockedProfit > 0
        vm.warp(1_789_000_000); // foundry default timestamp is 1; v1 notify() needs lastNotify + lockDuration <= now
        vm.startPrank(alice);
        IERC20(cusdAddr).approve(stcusdAddr, type(uint256).max);
        IERC4626(stcusdAddr).deposit(5_000e18, alice);
        IERC20(cusdAddr).transfer(stcusdAddr, 100e18); // yield arrives
        vm.stopPrank();
        IV1StakedCap(stcusdAddr).notify();
        vm.warp(block.timestamp + 6 hours); // half vested

        stablecoinImpl = address(new Stablecoin());
        wrapperImpl = address(new Wrapper());
    }

    function _setBal(address who, uint256 amount) internal {
        vm.store(cusdAddr, keccak256(abi.encode(who, SLOT_ERC20)), bytes32(amount));
    }

    function test_TABLE_v1State() public view {
        console2.log("v1 cUSD name/symbol", ERC20(cusdAddr).name(), ERC20(cusdAddr).symbol());
        console2.log("v1 cUSD totalSupply", IERC20(cusdAddr).totalSupply());
        console2.log("v1 cUSD Initializable._initialized", uint256(vm.load(cusdAddr, SLOT_INIT)));
        console2.log("v1 cUSD ERC4626 namespace", vm.toString(vm.load(cusdAddr, SLOT_ERC4626)));
        console2.log("v1 cUSD AccessManaged namespace", vm.toString(vm.load(cusdAddr, SLOT_ACCESS_MANAGED)));
        console2.log("v1 cUSD cap.storage.Access", vm.toString(vm.load(cusdAddr, SLOT_V1_ACCESS)));
        console2.log("v1 cUSD nonces(alice) [permit exists]", IV1CapToken(cusdAddr).nonces(alice));
        console2.log("v1 stcUSD Initializable._initialized", uint256(vm.load(stcusdAddr, SLOT_INIT)));
        console2.log("v1 stcUSD ERC4626 namespace", vm.toString(vm.load(stcusdAddr, SLOT_ERC4626)));
        console2.log("v1 stcUSD totalAssets", IERC4626(stcusdAddr).totalAssets());
        console2.log("v1 stcUSD lockedProfit", IV1StakedCap(stcusdAddr).lockedProfit());
        console2.log("cUSD.balanceOf(stcUSD)", IERC20(cusdAddr).balanceOf(stcusdAddr));
    }

    // 1. initializer reverts
    function test_FAIL_1_initializeRunsOnUpgradedProxy() public {
        UUPSUpgradeable(cusdAddr)
            .upgradeToAndCall(
                stablecoinImpl,
                abi.encodeCall(
                    Stablecoin.initialize, (address(ac), address(usdc), "cap USD", "cUSD", makeAddr("irm"), address(0))
                )
            );
    }

    function test_initializeRevertsInvalidInitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(cusdAddr)
            .upgradeToAndCall(
                stablecoinImpl,
                abi.encodeCall(
                    Stablecoin.initialize, (address(ac), address(usdc), "cap USD", "cUSD", makeAddr("irm"), address(0))
                )
            );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        UUPSUpgradeable(stcusdAddr)
            .upgradeToAndCall(wrapperImpl, abi.encodeCall(Wrapper.initialize, (address(ac), cusdAddr)));
    }

    // 2. bare upgrade: asset lost, redemption dead, permit gone
    function test_FAIL_2_assetSurvives() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        assertEq(Stablecoin(cusdAddr).asset(), address(usdc), "asset");
        assertEq(Stablecoin(cusdAddr).underlyingDecimals(), 6, "underlyingDecimals");
    }

    function test_FAIL_2b_holderCanRedeem() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        vm.prank(alice);
        Stablecoin(cusdAddr).instantRedeem(1e18, alice, alice);
    }

    function test_TABLE_2_bareUpgrade() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        Stablecoin c = Stablecoin(cusdAddr);
        console2.log("name/symbol/decimals", c.name(), c.symbol(), c.decimals());
        console2.log("totalSupply", c.totalSupply());
        console2.log("asset()", c.asset());
        console2.log("underlyingDecimals()", c.underlyingDecimals());
        console2.log("authority()", c.authority());
        console2.log("irm()", c.irm());
        console2.log("stablecoin()", c.stablecoin());
        console2.log("totalAssets() [S/1e18]", c.totalAssets());
        console2.log("previewDeposit(1e6)", c.previewDeposit(1e6));
        console2.log("previewMint(1e18)", c.previewMint(1e18));
        (bool ok,) = cusdAddr.call(abi.encodeCall(c.unlockedSupply, ()));
        console2.log("unlockedSupply() ok?", ok);
        (ok,) = cusdAddr.call(abi.encodeWithSignature("nonces(address)", alice));
        console2.log("nonces(alice) ok? [permit removed]", ok);
        vm.prank(alice);
        (ok,) = cusdAddr.call(abi.encodeCall(c.requestRedeem, (4_000e18, alice, alice)));
        console2.log("alice requestRedeem(4000) ok?", ok);
        console2.log("alice balance after", c.balanceOf(alice));
        vm.prank(alice);
        (ok,) = cusdAddr.call(abi.encodeCall(c.claimableRedeemRequest, (1, alice)));
        console2.log("claimableRedeemRequest ok?", ok);
    }

    // 3. bricked upgrade authority
    function test_FAIL_3_proxyStillUpgradeable() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
    }

    function test_upgradeBrickedSelectors() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        IAccessManaged(cusdAddr).setAuthority(address(ac));

        UUPSUpgradeable(stcusdAddr).upgradeToAndCall(wrapperImpl, "");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        UUPSUpgradeable(stcusdAddr).upgradeToAndCall(wrapperImpl, "");
    }

    // 4. wrapper never opts in, deposits dead, share price jumps
    function test_FAIL_4_wrapperOptedIn() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        UUPSUpgradeable(stcusdAddr).upgradeToAndCall(wrapperImpl, "");
        assertTrue(IPremiumVesting(cusdAddr).optedIn(stcusdAddr), "stcUSD opted in");
    }

    function test_FAIL_4b_wrapperDepositWorks() public {
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        UUPSUpgradeable(stcusdAddr).upgradeToAndCall(wrapperImpl, "");
        vm.prank(bob);
        IERC20(cusdAddr).approve(stcusdAddr, type(uint256).max);
        vm.prank(bob);
        IERC4626(stcusdAddr).deposit(1e18, bob);
    }

    function test_TABLE_4_wrapper() public {
        uint256 before = IERC4626(stcusdAddr).totalAssets();
        uint256 locked = IV1StakedCap(stcusdAddr).lockedProfit();
        UUPSUpgradeable(cusdAddr).upgradeToAndCall(stablecoinImpl, "");
        UUPSUpgradeable(stcusdAddr).upgradeToAndCall(wrapperImpl, "");
        uint256 afterUp = IERC4626(stcusdAddr).totalAssets();
        console2.log("stcUSD totalAssets before (v1)", before);
        console2.log("stcUSD lockedProfit before (v1)", locked);
        console2.log("stcUSD totalAssets after (HEAD: balance + claimable)", afterUp);
        console2.log("jump == lockedProfit?", afterUp - before == locked);
        console2.log("optedIn(stcUSD)", IPremiumVesting(cusdAddr).optedIn(stcusdAddr));
        vm.startPrank(alice);
        (bool ok,) = stcusdAddr.call(abi.encodeCall(IERC4626.redeem, (1e18, alice, alice)));
        console2.log("alice stcUSD.redeem(1e18) ok?", ok);
        vm.stopPrank();
    }
}
