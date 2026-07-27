// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { IMarket } from "../../contracts/interfaces/IMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract RewarderTest is CapDeployer {
    address internal stranger = makeAddr("stranger");
    uint64 internal managerId = MANAGER_ROLE;
    uint64 internal borrowerId = BORROWER_ROLE;
    Market internal market;
    address internal senior;
    address internal junior;

    function setUp() public {
        _deployCap();
        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("Market A", managerId, borrowerId);
        market = Market(marketAddr);
    }

    function test_setStakedStablecoin_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.setStakedStablecoin(address(0xCAFE));
    }

    function test_setStakedStablecoin_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IMarket.SetStakedStablecoin(address(0xCAFE));
        market.setStakedStablecoin(address(0xCAFE));
    }

    function test_setJuniorSplit_onlyAuthority() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.setJuniorSplit(0.5e27);
    }

    function test_setJuniorSplit_byManager() public {
        vm.expectEmit(false, false, false, true);
        emit IMarket.SetJuniorSplit(0.5e27);
        market.setJuniorSplit(0.5e27);
    }

    function test_setJuniorSplit_tooHigh_reverts() public {
        vm.expectRevert(IMarket.InvalidJuniorSplit.selector);
        market.setJuniorSplit(1e27 + 1);
    }

    function test_claimable_zeroInitially() public view {
        assertEq(market.claimable(junior), 0);
        assertEq(market.claimable(senior), 0);
    }
}
