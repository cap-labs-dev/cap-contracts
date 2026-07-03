// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Lender } from "../../../contracts/cap/Lender.sol";
import { ILender } from "../../../contracts/interfaces/ILender.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { MockOracle } from "../../shared/mocks/MockOracle.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Minimal underwriter tranche stand-in for reward routing tests.
contract MockTranche {
    uint256 internal _activeSupply;

    function setActiveSupply(uint256 v) external {
        _activeSupply = v;
    }

    function activeSupply() external view returns (uint256) {
        return _activeSupply;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Unit tests for the Lender contract in isolation with mocked dependencies.
contract LenderUnitTest is BaseTest {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Lender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LENDER_STORAGE_LOCATION =
        0xd6af1ec8a1789f5ada2b972bd1569f7c83af2e268be17cd65efe8474ebf08800;

    Lender internal lender;
    MockOracle internal oracle;
    MockIRM internal irm;
    MockERC20 internal collateral;
    MockTranche internal senior;
    MockTranche internal junior;

    address internal stranger = makeAddr("stranger");

    bytes32 internal constant MARKET = keccak256("market");

    function setUp() public {
        _setUpAccessManager();
        oracle = new MockOracle();
        irm = new MockIRM();
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);
        senior = new MockTranche();
        junior = new MockTranche();

        oracle.setPrice(address(collateral), 1e27);

        Lender impl = new Lender();
        lender = Lender(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Lender.initialize,
                    (
                        address(accessManager),
                        address(0xCAFE), // stablecoin (mocked when needed)
                        address(0xBEEF), // underwriter beacon (unused in these tests)
                        address(oracle),
                        address(0xFEED), // vault (mocked when needed)
                        address(irm)
                    )
                )
            )
        );

        lender.setDefaultBuffer(0.1e27);
        lender.setDefaultLt(0.8e27);
        lender.setMultiplierLimits(0, 10e27);

        _setMarketAsset(MARKET, address(collateral));
        _setMarketTranches(MARKET, address(senior), address(junior));
        _setMarketVariable(MARKET, true);
        _setMarketMultiplier(MARKET, 0);

        vm.prank(address(senior));
        lender.setJuniorSplit(MARKET, 0.5e27);
    }

    // --- init / upgrade ---

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        lender.initialize(
            address(accessManager), address(0xCAFE), address(0xBEEF), address(oracle), address(0xFEED), address(irm)
        );
    }

    function test_upgrade_authorized() public {
        Lender newImpl = new Lender();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
        assertEq(lender.getPrice(MARKET), 1e27);
    }

    function test_upgrade_unauthorized_reverts() public {
        Lender newImpl = new Lender();
        vm.prank(stranger);
        vm.expectRevert();
        UUPSUpgradeable(address(lender)).upgradeToAndCall(address(newImpl), "");
    }

    // --- view wrappers (exercise external dispatch paths on Lender.sol) ---

    function test_getPrice_readsOracle() public view {
        assertEq(lender.getPrice(MARKET), 1e27);
    }

    function test_supplyIndex_externalWrapper() public {
        assertEq(lender.supplyIndex(MARKET), RAY);
    }

    function test_underwriterIndex_externalWrapper() public {
        vm.mockCall(address(irm), abi.encodeWithSignature("index(bytes32)", MARKET), abi.encode(1.5e27));
        assertEq(lender.trancheIndex(MARKET), 1.5e27);
    }

    function test_index_externalWrapper() public {
        vm.mockCall(address(irm), abi.encodeWithSignature("index(bytes32)", MARKET), abi.encode(2e27));
        assertEq(lender.index(MARKET), 2e27);
    }

    function test_scaledDebt_and_debt_externalWrappers() public {
        _setScaledDebt(MARKET, 100e18);
        vm.mockCall(address(irm), abi.encodeWithSignature("index(bytes32)", MARKET), abi.encode(2e27));

        assertEq(lender.scaledDebt(MARKET), 100e18);
        assertEq(lender.debt(MARKET), 200e18);
    }

    function test_utilization_zeroWhenNoCredit() public {
        address vault = address(0xFEED);
        vm.mockCall(
            vault,
            abi.encodeWithSignature("balanceOf(address,address)", address(senior), address(collateral)),
            abi.encode(0)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("balanceOf(address,address)", address(junior), address(collateral)),
            abi.encode(0)
        );
        assertEq(lender.utilization(MARKET), 0);
    }

    function test_borrowCap_externalWrapper() public {
        lender.setBorrowCap(MARKET, 500e18);
        assertEq(lender.borrowCap(MARKET), 500e18);
    }

    function test_claimableSupplyReward_externalWrapper() public view {
        assertEq(lender.claimableSupplyReward(), 0);
    }

    // --- auth ---

    function test_setOracle_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setOracle(address(0xdead));
    }

    function test_setStcUSD_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setStcUSD(address(0xCAFE));
    }

    function test_setStcUSD_emits() public {
        vm.expectEmit(false, false, false, true);
        emit ILender.SetStcUSD(address(0xCAFE));
        lender.setStcUSD(address(0xCAFE));
    }

    function test_setJuniorSplit_onlyTranche() public {
        vm.prank(stranger);
        vm.expectRevert(ILender.Unauthorized.selector);
        lender.setJuniorSplit(MARKET, 0.25e27);
    }

    function test_setJuniorSplit_tooHigh_reverts() public {
        vm.prank(address(senior));
        vm.expectRevert(ILender.InvalidJuniorSplit.selector);
        lender.setJuniorSplit(MARKET, RAY + 1);
    }

    function test_setDefaultBuffer_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        lender.setDefaultBuffer(0.2e27);
    }

    // --- reward routing ---

    function test_updateRewards_bothTranchesEmpty_routesPremiumToSupplyReward() public {
        senior.setActiveSupply(0);
        junior.setActiveSupply(0);
        _setScaledDebt(MARKET, 100e18);

        vm.mockCall(address(irm), abi.encodeWithSignature("variableIndex()"), abi.encode(RAY));
        vm.mockCall(address(irm), abi.encodeWithSignature("index(bytes32)", MARKET), abi.encode(2e27));

        lender.updateRewards(MARKET);

        assertEq(lender.claimableSupplyReward(), 200e18);
    }

    // --- storage helpers ---

    function _marketSlot(bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketId, uint256(LENDER_STORAGE_LOCATION) + 2));
    }

    function _setMarketAsset(bytes32 marketId, address asset) internal {
        vm.store(address(lender), _marketSlot(marketId), bytes32(uint256(uint160(asset))));
    }

    function _setScaledDebt(bytes32 marketId, uint256 scaledDebt) internal {
        vm.store(address(lender), bytes32(uint256(_marketSlot(marketId)) + 5), bytes32(scaledDebt));
    }

    function _setMarketTranches(bytes32 marketId, address seniorUnderwriter, address juniorUnderwriter) internal {
        bytes32 marketSlot = _marketSlot(marketId);
        vm.store(address(lender), bytes32(uint256(marketSlot) + 6), bytes32(uint256(uint160(seniorUnderwriter))));
        vm.store(address(lender), bytes32(uint256(marketSlot) + 7), bytes32(uint256(uint160(juniorUnderwriter))));
    }

    function _setMarketVariable(bytes32 marketId, bool variable) internal {
        vm.store(address(lender), bytes32(uint256(_marketSlot(marketId)) + 8), bytes32(uint256(variable ? 1 : 0)));
    }

    function _setMarketMultiplier(bytes32 marketId, uint256 multiplier) internal {
        vm.store(address(lender), bytes32(uint256(_marketSlot(marketId)) + 9), bytes32(multiplier));
    }
}
