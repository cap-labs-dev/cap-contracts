// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

interface IContinuousClearingAuctionFactory {
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address distributionContract);
}

contract DeployAuction is Script {
    struct AuctionParameters {
        address currency; // token to raise funds in. Use address(0) for ETH
        address tokensRecipient; // address to receive leftover tokens
        address fundsRecipient; // address to receive all raised funds
        uint64 startBlock; // Block which the first step starts
        uint64 endBlock; // When the auction finishes
        uint64 claimBlock; // Block when the auction can claimed
        uint256 tickSpacing; // Fixed granularity for prices
        address validationHook; // Optional hook called before a bid
        uint256 floorPrice; // Starting floor price for the auction
        uint128 requiredCurrencyRaised; // Amount of currency required to be raised for the auction to graduate
        bytes auctionStepsData; // Packed bytes describing token issuance schedule
    }

    function run() external {
        vm.startBroadcast();
        IContinuousClearingAuctionFactory continuousClearingAuctionFactory =
            IContinuousClearingAuctionFactory(0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5);

        AuctionParameters memory auctionParameters = AuctionParameters({
            currency: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            tokensRecipient: address(0xA388cf78Ba2AbFfBE6dFcc0a4211cDBD430B69fd),
            fundsRecipient: address(0xA388cf78Ba2AbFfBE6dFcc0a4211cDBD430B69fd),
            startBlock: 24420030, // 2026-02-09 14:00:00 UTC
            endBlock: 24484830, // 2026-02-18 14:00:00 UTC
            claimBlock: 24484830, // 2026-02-18 14:00:00 UTC
            tickSpacing: 11884224377139, // 1% of floor price
            validationHook: address(0xccCc021dB9dE6ab185d752Fc135029EA76efcCcc),
            floorPrice: 1188422437713900, // 0.015 USDC per token ((0.015 * 10^6) / 10^18) * 2^96
            requiredCurrencyRaised: 0, // 0 minimum, auction will always complete
            auctionStepsData: encodeAuctionStepsData() // auction steps data
        });

        address auction = continuousClearingAuctionFactory.initializeDistribution(
            address(0xcCcC87d42dB3d35018eCAe712A0Bc53e79d9cCcc), // rCAP token
            1_000_000_000e18, // 1B rCAP tokens
            abi.encode(auctionParameters), // config data
            bytes32(0) // salt
        );

        console.log("Auction deployed to:", address(auction));
        vm.stopBroadcast();
    }

    function encodeAuctionStepsData() internal pure returns (bytes memory auctionStepsData) {
        console.log("Encoding auction steps data...");
        auctionStepsData = abi.encodePacked(auctionStepsData, abi.encodePacked(uint24(0), uint40(14400))); // 0 rCAP tokens, 14400 blocks (2 days)
        auctionStepsData = abi.encodePacked(auctionStepsData, abi.encodePacked(uint24(69), uint40(7200))); // 0.00069% tokens per block * 7200 blocks (1 day) = 4.968% of total tokens
        auctionStepsData = abi.encodePacked(auctionStepsData, abi.encodePacked(uint24(139), uint40(28800))); // 0.00139% tokens per block * 28800 blocks (4 days) = 40.032% of total tokens
        auctionStepsData = abi.encodePacked(auctionStepsData, abi.encodePacked(uint24(208), uint40(14399))); // 0.00208% tokens per block * 14399 blocks (2 days) = 29.94992% of total tokens
        auctionStepsData = abi.encodePacked(auctionStepsData, abi.encodePacked(uint24(2505008), uint40(1))); // 25.05008% tokens per block * 1 blocks = 25.05008% of total tokens

        return auctionStepsData;
    }
}
