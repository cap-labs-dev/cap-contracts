// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-5 (model-owned in rounds 1-2; round-3 P13/I38 owned by WS-D).
/// `BaseMarket.setLt` (:89-96) only checks `lt <= 1e27` and `lt > buffer`; for
/// `lt > 1/(1+bonus)` (0.9804 at bonus 2%) a market can have `unrecoverableDebt() > 0` while
/// `healthiness() >= 1e27`, so `liquidate` reverts `Healthy()` and only GUARDIAN `writeOff` acts.
contract R1_L5_LtAboveBonusBound is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_L5_setLtPermitsHealthLaggingRecoverability() public {
        MarketBundle memory b = _createReadyMarket("M");
        b.market.setLt(0.99e27); // GUARDIAN; accepted
        b.market.setLtv(0.89e27); // owner; ltv + buffer <= lt
        b.market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 890e18);

        _setPrice(address(collateral), 0.9e18); // capital 900: 0.98*900 < 890 <= 0.99*900
        uint256 health = b.market.healthiness();
        uint256 unrec = b.market.unrecoverableDebt();
        emit log_named_uint("lt (ray)           ", b.market.lt());
        emit log_named_uint("healthiness (ray)  ", health);
        emit log_named_uint("recoverableDebt    ", b.market.recoverableDebt());
        emit log_named_uint("unrecoverableDebt  ", unrec);
        assertGe(health, 1e27, "market reports healthy");
        assertGt(unrec, 0, "yet cUSD holders are already exposed");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        b.market.liquidate(defaultLiquidator, 100e18);

        uint256 written = b.market.writeOff(); // GUARDIAN can write off a "healthy" market
        emit log_named_uint("written off on a healthy market", written);
        assertEq(stablecoin.badDebt(), written);

        // desired property (I38): unrecoverableDebt() > 0 => healthiness() < 1e27
        assertLt(health, 1e27, "health must lead recoverability: lt*(1+bonus) <= 1e27 is not enforced");
    }

    function test_L5_boundNotEnforcedBySetter() public {
        MarketBundle memory b = _createReadyMarket("M");
        uint256 bound = 1e27 * 1e27 / (1e27 + irm.liquidationBonus());
        emit log_named_uint("1/(1+bonus) (ray)", bound);
        b.market.setLt(bound + 1e24);
        assertLe(b.market.lt(), bound, "setLt must reject lt*(1+bonus) > 1e27");
    }
}
