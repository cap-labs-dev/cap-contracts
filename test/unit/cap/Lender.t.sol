// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../../contracts/cap/Market.sol";
import { IMarket } from "../../../contracts/interfaces/IMarket.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { MockOracle } from "../../shared/mocks/MockOracle.sol";

contract MockTranche {
    address internal _asset;
    address internal _market;
    uint256 internal _activeSupply;

    constructor(address asset_, address market_) {
        _asset = asset_;
        _market = market_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function market() external view returns (address) {
        return _market;
    }

    function setActiveSupply(uint256 v) external {
        _activeSupply = v;
    }

    function activeSupply() external view returns (uint256) {
        return _activeSupply;
    }

    function activeAssets() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Unit tests for the Market contract in isolation with mocked dependencies.
contract MarketUnitTest is BaseTest {
    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Market")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant MARKET_STORAGE_LOCATION =
        0xbb08105a09d87dbda58bb8040836744d08c16a52e5cfed46ffdfe51c9f4b6e00;

    Market internal market;
    MockOracle internal oracle;
    MockIRM internal irm;
    MockERC20 internal collateral;
    MockTranche internal senior;
    MockTranche internal junior;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpAccessManager();
        oracle = new MockOracle();
        irm = new MockIRM();
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        Market impl = new Market();
        market = Market(
            _deployProxy(
                address(impl),
                abi.encodeCall(Market.initialize, (address(accessManager), address(collateral), "Market"))
            )
        );

        oracle.setPrice(address(collateral), 1e27);

        senior = new MockTranche(address(collateral), address(market));
        junior = new MockTranche(address(collateral), address(market));

        market.setSeniorTranche(address(senior));
        market.setJuniorTranche(address(junior));
        market.setJuniorSplit(0.5e27);
    }

    function test_initialize_cannotReinit() public {
        vm.expectRevert();
        market.initialize(address(accessManager), address(collateral), "Market");
    }

    function test_setOracle_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.setOracle(address(0xdead));
    }

    function test_setJuniorSplit_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.setJuniorSplit(0.25e27);
    }

    function test_setJuniorSplit_tooHigh_reverts() public {
        vm.expectRevert(IMarket.InvalidJuniorSplit.selector);
        market.setJuniorSplit(RAY + 1);
    }

    function test_setBorrowCap_effect() public {
        market.setBorrowCap(500e18);
        assertEq(market.borrowCap(), 500e18);
    }
}
