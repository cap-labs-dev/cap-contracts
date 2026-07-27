// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { IMarket } from "../../contracts/interfaces/IMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockOracle } from "../shared/mocks/MockOracle.sol";

contract MarketTest is CapDeployer {
    address internal stranger = makeAddr("stranger");
    uint64 internal managerId = MANAGER_ROLE;
    uint64 internal borrowerId = BORROWER_ROLE;
    Market internal market;

    function setUp() public {
        _deployCap();
    }

    function _market() internal returns (Market m) {
        address marketAddr;
        (marketAddr,,) = _createMarket("Market A", managerId, borrowerId);
        m = Market(marketAddr);
    }

    function test_setBorrowCap_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setBorrowCap(1e18);
    }

    function test_setBorrowCap_effect() public {
        market = _market();
        market.setBorrowCap(123e18);
        assertEq(market.borrowCap(), 123e18);
    }

    function test_setOracle_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setOracle(address(0xdead));
    }

    function test_setTargetHealth_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setTargetHealth(1.2e27);
    }

    function test_createMarket_returnsNonZeroAddresses() public {
        address marketAddr;
        address senior;
        address junior;
        (marketAddr, senior, junior) = _createMarket("Market A", managerId, borrowerId);

        assertTrue(marketAddr != address(0));
        assertTrue(senior != address(0));
        assertTrue(junior != address(0));
        assertTrue(senior != junior);
        assertTrue(registry.isMarket(marketAddr));
        assertTrue(registry.isTranche(senior));
        assertTrue(registry.isTranche(junior));

        assertEq(Tranche(senior).asset(), address(collateral));
        assertEq(Tranche(junior).asset(), address(collateral));
        assertEq(Market(marketAddr).seniorTranche(), senior);
        assertEq(Market(marketAddr).juniorTranche(), junior);
    }

    function test_setLtv_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setLtv(0.4e27);

        market.setLtv(0.4e27);
    }

    function test_setLtv_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IMarket.InvalidLtv.selector);
        market.setLtv(0.75e27);
    }

    function test_setBuffer_and_setLt_success() public {
        market = _market();
        market.setBuffer(0.2e27);
        market.setLt(0.85e27);
    }

    function test_setOracle_effect() public {
        market = _market();
        MockOracle newOracle = new MockOracle();
        newOracle.setPrice(address(collateral), 2e27);

        market.setOracle(address(newOracle));
        (uint256 price,) = newOracle.getPrice(address(collateral));
        assertEq(price, 2e27);
    }

    function test_setMultiplier_invalid_reverts() public {
        market = _market();
        vm.expectRevert(IMarket.InvalidMultiplier.selector);
        market.setMultiplier(11e27);
    }

    function test_setMultiplier_success() public {
        market = _market();
        market.setMultiplier(2e27);
    }

    function test_setInterestType_onlyAuthority() public {
        market = _market();
        vm.prank(stranger);
        vm.expectRevert();
        market.setInterestType(false);
    }

    function test_setInterestType_success() public {
        market = _market();
        market.setInterestType(false);
    }
}
