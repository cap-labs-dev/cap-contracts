// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";

/// WS-C / H5 model + 6-decimal sanity. Informational: logs how far health may degrade through
/// withdrawals alone, and checks the 6-decimal conversion paths do not revert.
contract C7_BufferAndDecimals is CapDeployer {
    address x = makeAddr("x");
    address y = makeAddr("y");

    function setUp() public {
        _deployCap();
    }

    function test_H5_healthDegradesToBufferEdgeWithoutBorrowerAction() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(b.tranche1Addr, x, 500e18);
        _fundTranche(b.tranche1Addr, y, 500e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max); // to the ltv line
        emit log_named_uint("debt", b.market.totalDebt());
        emit log_named_uint("health at borrow (ray)", b.market.healthiness());

        // x queues everything and claims whatever is unlocked; y does nothing
        uint256 xShares = b.tranche1.balanceOf(x);
        vm.prank(x);
        uint256 id = b.tranche1.requestRedeem(xShares, x, x);
        uint256 c = b.tranche1.claimableRedeemRequest(id, x);
        vm.prank(x);
        b.tranche1.redeem(id, c, x, x);
        emit log_named_uint("x shares claimed out", c);
        emit log_named_uint("health after x exits (ray)", b.market.healthiness());
        emit log_named_uint("credit limit now", b.market.creditLimit());
        emit log_named_uint("lt - buffer (ray)", b.market.lt() - b.market.buffer());
        // withdrawals are permitted down to health = lt / (lt - buffer) = 1.142857..., a state the
        // borrow gate (ltv) would never have allowed the borrower to reach directly
        assertGe(b.market.healthiness(), 1.14e27);
        assertLt(b.market.healthiness(), 1.15e27);
        assertLt(b.market.creditLimit(), b.market.totalDebt(), "over the borrow line, no borrower action");

        // a further 12.5% collateral move liquidates, and x's queued remainder is slashed like y's
        oracle.setPrice(address(collateral), 0.87e18);
        assertLt(b.market.healthiness(), 1e27);
    }

    function test_sixDecimalCollateralPaths() public {
        MockERC20 usdc = _newCollateral("USDC", "USDC", 6, 1e18);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        (address m, address[] memory ts) = _createMarket("Six", defaultMarketOwner, defaultBorrower, assets, w);
        FloatingMarket market = FloatingMarket(m);
        Tranche t = Tranche(ts[0]);
        _setMarketSlopes(m);
        _fundTranche(address(t), address(usdc), x, 1_000e6);
        assertEq(t.decimals(), 6);
        assertEq(t.totalCapital(), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        emit log_named_uint("lockedValue (USD)", market.lockedValue(address(t)));
        emit log_named_uint("unlockedSupply (6dp shares)", t.unlockedSupply());
        assertEq(t.unlockedSupply(), uint256(1_000e6) - market.lockedValue(address(t)) * 1e6 / 1e18);
        // slash rounding with 6 decimals
        oracle.setPrice(address(usdc), 0.4e18);
        _mintStable(defaultLiquidator, 10e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashedValue) = market.liquidate(defaultLiquidator, 10e18);
        emit log_named_uint("repaid", repaid);
        emit log_named_uint("slashedValue", slashedValue);
        emit log_named_uint("liquidator received usdc units", usdc.balanceOf(defaultLiquidator));
        // credited value vs delivered value differ by < 1 asset unit
        uint256 delivered = usdc.balanceOf(defaultLiquidator) * 0.4e18 / 1e6;
        assertLe(slashedValue - delivered, 0.4e18 / 1e6 + 1);
    }
}
