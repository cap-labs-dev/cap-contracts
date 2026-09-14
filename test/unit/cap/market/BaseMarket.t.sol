// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseMarket } from "../../../../contracts/cap/market/BaseMarket.sol";
import { BaseTest } from "../../../shared/BaseTest.sol";

contract BareMarket is BaseMarket {
    function initialize(address authority) external initializer {
        __AccessManaged_init(authority);
    }
}

/// @notice Hits the empty {BaseMarket-totalDebt} body that every concrete market overrides.
contract BaseMarketTest is BaseTest {
    function test_baseTotalDebtIsZero() public {
        _setUpAccessManager();
        BareMarket market = BareMarket(
            _deployProxy(address(new BareMarket()), abi.encodeCall(BareMarket.initialize, (address(accessManager))))
        );
        assertEq(market.totalDebt(), 0);
    }
}
