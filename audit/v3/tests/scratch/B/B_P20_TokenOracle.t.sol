// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IOracle } from "../../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockAdapter } from "../../../../../test/shared/mocks/MockChainlinkFeeds.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { console } from "forge-std/console.sol";

/// @dev 2% of every transfer is burned.
contract FeeERC20 is ERC20 {
    constructor() ERC20("Fee", "FEE") { }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 50;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev Returns whatever shape a test wants, to exercise Oracle._read's decoder.
contract ShapeAdapter {
    bytes public ret;
    bool public doRevert;

    function set(bytes memory r, bool rev) external {
        ret = r;
        doRevert = rev;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (doRevert) {
            bytes memory r = ret;
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
        return ret;
    }
}

contract B_P20_TokenOracle is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    // ── P20a: Vault.deposit mints the requested amount, not the received amount ──

    function test_P20_feeOnTransfer_vaultBecomesInsolventForThatAsset() public {
        FeeERC20 fee = new FeeERC20();
        address a = makeAddr("a");
        address b = makeAddr("b");
        fee.mint(a, 100e18);
        fee.mint(b, 100e18);
        vm.startPrank(a);
        fee.approve(address(vault), 100e18);
        vault.deposit(address(fee), 100e18, a);
        vm.stopPrank();
        vm.startPrank(b);
        fee.approve(address(vault), 100e18);
        vault.deposit(address(fee), 100e18, b);
        vm.stopPrank();

        assertEq(vault.balanceOf(a, address(fee)), 100e18, "credited the nominal amount");
        assertEq(fee.balanceOf(address(vault)), 196e18, "holds 2% less");

        vm.prank(a);
        vault.withdraw(address(fee), 100e18, a);
        vm.prank(b);
        vm.expectRevert();
        vault.withdraw(address(fee), 100e18, b);
        console.log("I12 broken: 6909 supply 100e18 vs ERC20 on hand", fee.balanceOf(address(vault)));
    }

    /// A tranche on such an asset: the first full slash reverts inside Vault.withdraw, so the
    /// liquidation reverts and the market cannot be brought back to health.
    function test_P20_feeOnTransfer_trancheSlashBricksLiquidation() public {
        FeeERC20 fee = new FeeERC20();
        _setPrice(address(fee), 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(fee);
        (address m, address[] memory tranches) =
            _createMarket("Fee", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        FloatingMarket market = FloatingMarket(m);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(tranches[0], makeAddr("seniorLP"), 1_000e18);

        // junior on the fee token: 100 nominal, 98 on hand
        address jLP = makeAddr("juniorLP");
        fee.mint(jLP, 100e18);
        vm.startPrank(jLP);
        fee.approve(address(vault), 100e18);
        vault.deposit(address(fee), 100e18, jLP);
        vault.setOperator(tranches[1], true);
        vm.stopPrank();
        _admitDepositor(tranches[1], jLP);
        vm.prank(jLP);
        Tranche(tranches[1]).deposit(100e18, jLP);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.4e18);
        assertLt(market.healthiness(), 1e27, "liquidatable");

        _mintStable(defaultLiquidator, 500e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert();
        market.liquidate(defaultLiquidator, 500e18);
        console.log(
            "liquidate reverted: Vault holds",
            fee.balanceOf(address(vault)),
            "vs tranche 6909 balance",
            Tranche(tranches[1]).totalAssets()
        );
    }

    // ── P20b: Oracle._read decoding ──────────────────────────────────────────

    function _chain(address primary, address secondary, uint256 staleness)
        internal
        pure
        returns (IOracle.Sources[] memory hops)
    {
        hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({ adapter: primary, payload: hex"01", staleness: staleness });
        hops[0].secondary = IOracle.Source({ adapter: secondary, payload: hex"01", staleness: staleness });
    }

    function test_P20_oracleRead_shapes() public {
        ShapeAdapter p = new ShapeAdapter();
        ShapeAdapter s = new ShapeAdapter();
        address asset = makeAddr("asset");
        vm.warp(1_000_000);
        s.set(abi.encode(uint256(2e18), block.timestamp), false);

        // primary answers (0, now): treated as unusable, secondary used
        p.set(abi.encode(uint256(0), block.timestamp), false);
        oracle.setSource(asset, _chain(address(p), address(s), 1 hours));
        assertEq(oracle.price(asset), 2e18, "zero answer falls to secondary");

        // primary returns 96 bytes: ignored, secondary used
        p.set(abi.encode(uint256(3e18), block.timestamp, uint256(0)), false);
        assertEq(oracle.price(asset), 2e18, "96-byte answer ignored");

        // primary returns 32 bytes: ignored
        p.set(abi.encode(uint256(3e18)), false);
        assertEq(oracle.price(asset), 2e18, "32-byte answer ignored");

        // primary reverts with 64 bytes of data: ignored (success is false)
        p.set(abi.encode(uint256(3e18), block.timestamp), true);
        assertEq(oracle.price(asset), 2e18, "64-byte revert ignored");

        // primary stamped in the future: accepted as fresh
        p.set(abi.encode(uint256(3e18), block.timestamp + 10 days), false);
        assertEq(oracle.price(asset), 3e18, "future timestamp accepted");

        // primary stamped type(uint256).max: accepted
        p.set(abi.encode(uint256(4e18), type(uint256).max), false);
        assertEq(oracle.price(asset), 4e18, "max timestamp accepted");

        // primary exactly at the staleness edge: accepted; one second past: secondary
        p.set(abi.encode(uint256(5e18), block.timestamp - 1 hours), false);
        assertEq(oracle.price(asset), 5e18, "edge accepted");
        p.set(abi.encode(uint256(5e18), block.timestamp - 1 hours - 1), false);
        assertEq(oracle.price(asset), 2e18, "past edge -> secondary");

        // both stale -> 0 (Tranche.getPrice reverts InvalidPrice)
        s.set(abi.encode(uint256(2e18), block.timestamp - 2 hours), false);
        assertEq(oracle.price(asset), 0, "both stale -> zero");
    }

    /// Two reads in one transaction always agree; the primary->secondary switch is a cross-block
    /// discontinuity of |p1 - p2|, not an intra-tx one.
    function test_P20_oracle_sameTxReadsAgree_crossBlockJump() public {
        ShapeAdapter p = new ShapeAdapter();
        ShapeAdapter s = new ShapeAdapter();
        address asset = makeAddr("asset2");
        vm.warp(1_000_000);
        p.set(abi.encode(uint256(1e18), block.timestamp), false);
        s.set(abi.encode(uint256(0.9e18), block.timestamp + 1 days), false);
        oracle.setSource(asset, _chain(address(p), address(s), 1 hours));
        uint256 r1 = oracle.price(asset);
        uint256 r2 = oracle.price(asset);
        assertEq(r1, r2, "same tx");
        assertEq(r1, 1e18);
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(oracle.price(asset), 0.9e18, "next block: primary stale, secondary answers 10% lower");
    }

    // ── Composability: one-block JIT opt-in around a permissionless chargePremium ──

    function test_JIT_optInAroundChargePremium_oneBlockCapture() public {
        (address m,,) = _createMarket("JIT");
        FloatingMarket market = FloatingMarket(m);
        capConfig.applyLiquiditySlopes = true;
        _configureMarketRates(market);
        market.setFixedCreditLimit(100_000e18);
        (, address t0,) = (m, address(0), address(0));
        t0;

        // fund tranches through the deployer's bundle helper
        address[] memory tr = _tranchesOf(market);
        _fundTranche(tr[0], makeAddr("seniorLP"), 5_000e18);
        _fundTranche(tr[1], makeAddr("juniorLP"), 1_000e18);

        // honest staker holds 1M cUSD opted in; attacker holds 1M cUSD
        address staker = makeAddr("staker");
        address attacker = makeAddr("attacker");
        _depositStable(staker, 1_000_000e18);
        _depositStable(attacker, 1_000_000e18);
        vm.prank(staker);
        stablecoin.optIn();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 2_000e18);
        vm.warp(block.timestamp + 30 days);

        (uint256 liqPremium,) = market.premium();
        console.log("liquidity premium about to be charged", liqPremium);

        // attacker: opt in, charge, hold one block, claim, opt out
        vm.startPrank(attacker);
        stablecoin.optIn();
        market.chargePremium();
        uint256 sameBlock = stablecoin.claim(attacker);
        vm.warp(block.timestamp + 12);
        uint256 oneBlock = stablecoin.claim(attacker);
        stablecoin.optOut();
        vm.stopPrank();

        console.log("captured same block", sameBlock);
        console.log("captured after one 12s block", oneBlock);
        // expected: P * (1 - (1 - 1/43200)^12) * 1/2
        uint256 expected = liqPremium * 12 / 43_200 / 2;
        console.log("first-order expectation", expected);
        assertEq(sameBlock, 0, "same-block capture is zero");
        assertApproxEqRel(oneBlock, expected, 0.01e18, "one block captures ~ P*12/43200 * share");
    }

    function _tranchesOf(FloatingMarket market) internal view returns (address[] memory out) {
        FloatingMarket.Tranche[] memory ts = market.tranches();
        out = new address[](ts.length);
        for (uint256 i; i < ts.length; ++i) {
            out[i] = ts[i].tranche;
        }
    }
}
