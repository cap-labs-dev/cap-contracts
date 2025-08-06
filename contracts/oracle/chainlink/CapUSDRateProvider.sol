// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../access/Access.sol";
import { ICapUSDRateProvider } from "../../interfaces/ICapUSDRateProvider.sol";
import { CapUSDRateProviderStorageUtils } from "../../storage/CapUSDRateProviderStorageUtils.sol";

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title cUSD Rate Provider
/// @author weso, Cap Labs
/// @notice cUSD Rate Provider contract
contract CapUSDRateProvider is ICapUSDRateProvider, CapUSDRateProviderStorageUtils, UUPSUpgradeable, Access {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ICapUSDRateProvider
    function initialize(address _accessControl, address _porFeed, address _cusd) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        CapUSDRateProviderStorage storage $ = getCapUSDRateProviderStorage();

        $.porFeed = _porFeed;
        $.cusd = _cusd;
    }

    /// @inheritdoc ICapUSDRateProvider
    function getRate() external view returns (uint256) {
        return Math.mulDiv(_getLatestReserve(getCapUSDRateProviderStorage().porFeed), 1e18, _getcUSDTotalSupply());
    }

    /// @dev Get cUSD total supply
    /// @return The total supply of cUSD
    function _getcUSDTotalSupply() internal view returns (uint256) {
        return IERC20(getCapUSDRateProviderStorage().cusd).totalSupply();
    }

    /// @dev Get the latest reserve value from the oracle
    /// @param feedAddress The address of the oracle feed
    /// @return The latest reserve value
    function _getLatestReserve(address feedAddress) private view returns (uint256) {
        AggregatorV3Interface reserveFeed = AggregatorV3Interface(feedAddress);
        (
            /*uint80 roundID*/
            ,
            int reserve,
            /*uint startedAt*/
            ,
            /*uint timeStamp*/
            ,
            /*uint80 answeredInRound*/
        ) = reserveFeed.latestRoundData();
        return uint256(reserve);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override checkAccess(bytes4(0)) { }
}
