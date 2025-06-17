// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { Network } from "../../contracts/delegation/providers/symbiotic/Network.sol";
import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";
import { FeeReceiver } from "../../contracts/feeReceiver/FeeReceiver.sol";
import { IMinter } from "../../contracts/interfaces/IMinter.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";
import { PriceOracle } from "../../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../../contracts/oracle/RateOracle.sol";
import { VaultAdapter } from "../../contracts/oracle/libraries/VaultAdapter.sol";
import { FractionalReserve } from "../../contracts/vault/FractionalReserve.sol";
import { Minter } from "../../contracts/vault/Minter.sol";
import { Vault } from "../../contracts/vault/Vault.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract CheckAccess is Script {
    AccessControl accessControl = AccessControl(0x32fd97A5196a6D98656a7F2f191Ae4732ad13170);
    /// @dev Delegation Contract Selectors
    Delegation delegation = Delegation(0xDB34C0849DE02ABC719740E147e6df4ffE4e8163);
    /// @dev Network Contract Selectors
    Network network = Network(0x0000000000000000000000000000000000000000);
    /// @dev Network Middleware Contract Selectors
    NetworkMiddleware networkMiddleware = NetworkMiddleware(0x0000000000000000000000000000000000000000);
    /// @dev Fee Auction Contract Selectors
    FeeAuction feeAuction = FeeAuction(0x019B65850E3ad55939169845551f3D9C512E52Cd);
    /// @dev Fee Receiver Contract Selectors
    FeeReceiver feeReceiver = FeeReceiver(0x0000000000000000000000000000000000000000);
    /// @dev Lender Contract Selectors
    Lender lender = Lender(0x1036C242ccE7a6632E2f2649F293eaa881835772);
    /// @dev Oracle Contract Selectors
    PriceOracle priceOracle = PriceOracle(0xe23680f14214c4c9238411d2a85e74A9297ECEF0);
    RateOracle rateOracle = RateOracle(0xe23680f14214c4c9238411d2a85e74A9297ECEF0);
    VaultAdapter vaultAdapter = VaultAdapter(0x0000000000000000000000000000000000000000);
    /// @dev cUSD Contract Selectors
    Minter minter = Minter(0xF79e8E7Ba2dDb5d0a7D98B1F57fCb8A50436E9aA);
    Vault vault = Vault(0xF79e8E7Ba2dDb5d0a7D98B1F57fCb8A50436E9aA);
    FractionalReserve fractionalReserve = FractionalReserve(0xF79e8E7Ba2dDb5d0a7D98B1F57fCb8A50436E9aA);
    DebtToken debtToken = DebtToken(0xe20fbE3467436bd6Dd7096aDf0770A0870bAe567);

    function run() external {
        vm.startBroadcast();

        console.log("Checking Access for Delegation Contract...");
        (bytes4[] memory selectors, string[] memory selectorsNames) = buildDelegationSelectors();
        checkRoles(selectors, selectorsNames, address(delegation), accessControl);
        console.log("");
        console.log("Checking Access for Network Contract...");
        (selectors, selectorsNames) = buildNetworkSelectors();
        // checkRoles(selectors, selectorsNames, address(network), accessControl);
        console.log("");
        console.log("Checking Access for Network Middleware Contract...");
        (selectors, selectorsNames) = buildNetworkMiddlewareSelectors();
        //checkRoles(selectors, selectorsNames, address(networkMiddleware), accessControl);
        console.log("");
        console.log("Checking Access for Fee Auction Contract...");
        (selectors, selectorsNames) = buildFeeAuctionSelectors();
        checkRoles(selectors, selectorsNames, address(feeAuction), accessControl);
        console.log("");
        console.log("Checking Access for Fee Receiver Contract...");
        (selectors, selectorsNames) = buildFeeReceiverSelectors();
        //checkRoles(selectors, selectorsNames, address(feeReceiver), accessControl);
        console.log("");
        console.log("Checking Access for Lender Contract...");
        (selectors, selectorsNames) = buildLenderSelectors();
        checkRoles(selectors, selectorsNames, address(lender), accessControl);
        console.log("");
        console.log("Checking Access for Price Oracle Contract...");
        (selectors, selectorsNames) = buildPriceOracleSelectors();
        checkRoles(selectors, selectorsNames, address(priceOracle), accessControl);
        console.log("");
        console.log("Checking Access for Rate Oracle Contract...");
        (selectors, selectorsNames) = buildRateOracleSelectors();
        checkRoles(selectors, selectorsNames, address(rateOracle), accessControl);
        console.log("");
        console.log("Checking Access for Minter Contract...");
        (selectors, selectorsNames) = buildMinterSelectors();
        checkRoles(selectors, selectorsNames, address(minter), accessControl);
        console.log("");
        console.log("Checking Access for Vault Contract...");
        (selectors, selectorsNames) = buildVaultSelectors();
        checkRoles(selectors, selectorsNames, address(vault), accessControl);
        console.log("");
        console.log("Checking Access for Fractional Reserve Contract...");
        (selectors, selectorsNames) = buildFractionalReserveSelectors();
        checkRoles(selectors, selectorsNames, address(fractionalReserve), accessControl);
        console.log("");
        console.log("Checking Access for Debt Token Contract...");
        (selectors, selectorsNames) = buildDebtTokenSelectors();
        checkRoles(selectors, selectorsNames, address(debtToken), accessControl);
        console.log("");
        vm.stopBroadcast();
    }

    function buildDelegationSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        string[] memory selectorsNames = new string[](8);
        selectors[0] = Delegation.slash.selector;
        selectorsNames[0] = "Delegation.slash";
        selectors[1] = Delegation.setLastBorrow.selector;
        selectorsNames[1] = "Delegation.setLastBorrow";
        selectors[2] = Delegation.addAgent.selector;
        selectorsNames[2] = "Delegation.addAgent";
        selectors[3] = Delegation.modifyAgent.selector;
        selectorsNames[3] = "Delegation.modifyAgent";
        selectors[4] = Delegation.distributeRewards.selector;
        selectorsNames[4] = "Delegation.distributeRewards";
        selectors[5] = Delegation.setLtvBuffer.selector;
        selectorsNames[5] = "Delegation.setLtvBuffer";
        selectors[6] = Delegation.registerNetwork.selector;
        selectorsNames[6] = "Delegation.registerNetwork";
        selectors[7] = bytes4(0);
        selectorsNames[7] = "Delegation.upgrade";
        return (selectors, selectorsNames);
    }

    function buildNetworkSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        string[] memory selectorsNames = new string[](3);
        selectors[0] = Network.registerMiddleware.selector;
        selectorsNames[0] = "Network.registerMiddleware";
        selectors[1] = Network.registerVault.selector;
        selectorsNames[1] = "Network.registerVault";
        selectors[2] = bytes4(0);
        selectorsNames[2] = "Network.upgrade";
        return (selectors, selectorsNames);
    }

    function buildNetworkMiddlewareSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        string[] memory selectorsNames = new string[](6);
        selectors[0] = NetworkMiddleware.registerAgent.selector;
        selectorsNames[0] = "NetworkMiddleware.registerAgent";
        selectors[1] = NetworkMiddleware.registerVault.selector;
        selectorsNames[1] = "NetworkMiddleware.registerVault";
        selectors[2] = NetworkMiddleware.setFeeAllowed.selector;
        selectorsNames[2] = "NetworkMiddleware.setFeeAllowed";
        selectors[3] = NetworkMiddleware.slash.selector;
        selectorsNames[3] = "NetworkMiddleware.slash";
        selectors[4] = NetworkMiddleware.distributeRewards.selector;
        selectorsNames[4] = "NetworkMiddleware.distributeRewards";
        selectors[5] = bytes4(0);
        selectorsNames[5] = "NetworkMiddleware.upgrade";
        return (selectors, selectorsNames);
    }

    function buildFeeAuctionSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        string[] memory selectorsNames = new string[](4);
        selectors[0] = FeeAuction.setStartPrice.selector;
        selectorsNames[0] = "FeeAuction.setStartPrice";
        selectors[1] = FeeAuction.setDuration.selector;
        selectorsNames[1] = "FeeAuction.setDuration";
        selectors[2] = FeeAuction.setMinStartPrice.selector;
        selectorsNames[2] = "FeeAuction.setMinStartPrice";
        selectors[3] = bytes4(0);
        selectorsNames[3] = "FeeAuction.upgrade";
        return (selectors, selectorsNames);
    }

    function buildFeeReceiverSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        string[] memory selectorsNames = new string[](3);
        selectors[0] = FeeReceiver.setProtocolFeePercentage.selector;
        selectorsNames[0] = "FeeReceiver.setProtocolFeePercentage";
        selectors[1] = FeeReceiver.setProtocolFeeReceiver.selector;
        selectorsNames[1] = "FeeReceiver.setProtocolFeeReceiver";
        selectors[2] = bytes4(0);
        selectorsNames[2] = "FeeReceiver.upgrade";
        return (selectors, selectorsNames);
    }

    function buildLenderSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        string[] memory selectorsNames = new string[](5);
        selectors[0] = Lender.addAsset.selector;
        selectorsNames[0] = "Lender.addAsset";
        selectors[1] = Lender.removeAsset.selector;
        selectorsNames[1] = "Lender.removeAsset";
        selectors[2] = Lender.pauseAsset.selector;
        selectorsNames[2] = "Lender.pauseAsset";
        selectors[3] = Lender.setMinBorrow.selector;
        selectorsNames[3] = "Lender.setMinBorrow";
        selectors[4] = bytes4(0);
        selectorsNames[4] = "Lender.upgrade";
        return (selectors, selectorsNames);
    }

    function buildPriceOracleSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        string[] memory selectorsNames = new string[](4);
        selectors[0] = PriceOracle.setPriceOracleData.selector;
        selectorsNames[0] = "PriceOracle.setPriceOracleData";
        selectors[1] = PriceOracle.setPriceBackupOracleData.selector;
        selectorsNames[1] = "PriceOracle.setPriceBackupOracleData";
        selectors[2] = PriceOracle.setStaleness.selector;
        selectorsNames[2] = "PriceOracle.setStaleness";
        selectors[3] = bytes4(0);
        selectorsNames[3] = "PriceOracle.upgrade";
        return (selectors, selectorsNames);
    }

    function buildRateOracleSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        string[] memory selectorsNames = new string[](5);
        selectors[0] = RateOracle.setMarketOracleData.selector;
        selectorsNames[0] = "RateOracle.setMarketOracleData";
        selectors[1] = RateOracle.setUtilizationOracleData.selector;
        selectorsNames[1] = "RateOracle.setUtilizationOracleData";
        selectors[2] = RateOracle.setBenchmarkRate.selector;
        selectorsNames[2] = "RateOracle.setBenchmarkRate";
        selectors[3] = RateOracle.setRestakerRate.selector;
        selectorsNames[3] = "RateOracle.setRestakerRate";
        selectors[4] = bytes4(0);
        selectorsNames[4] = "RateOracle.upgrade";
        return (selectors, selectorsNames);
    }

    function buildVaultAdapterSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        string[] memory selectorsNames = new string[](3);
        selectors[0] = VaultAdapter.setSlopes.selector;
        selectorsNames[0] = "VaultAdapter.setSlopes";
        selectors[1] = VaultAdapter.setLimits.selector;
        selectorsNames[1] = "VaultAdapter.setLimits";
        selectors[2] = bytes4(0);
        selectorsNames[2] = "VaultAdapter.upgrade";
        return (selectors, selectorsNames);
    }

    function buildMinterSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        string[] memory selectorsNames = new string[](4);
        selectors[0] = Minter.setFeeData.selector;
        selectorsNames[0] = "Minter.setFeeData";
        selectors[1] = Minter.setRedeemFee.selector;
        selectorsNames[1] = "Minter.setRedeemFee";
        selectors[2] = Minter.setWhitelist.selector;
        selectorsNames[2] = "Minter.setWhitelist";
        selectors[3] = bytes4(0);
        selectorsNames[3] = "Minter.upgrade";
        return (selectors, selectorsNames);
    }

    function buildVaultSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        string[] memory selectorsNames = new string[](11);
        selectors[0] = Vault.borrow.selector;
        selectorsNames[0] = "Vault.borrow";
        selectors[1] = Vault.repay.selector;
        selectorsNames[1] = "Vault.repay";
        selectors[2] = Vault.addAsset.selector;
        selectorsNames[2] = "Vault.addAsset";
        selectors[3] = Vault.removeAsset.selector;
        selectorsNames[3] = "Vault.removeAsset";
        selectors[4] = Vault.pauseAsset.selector;
        selectorsNames[4] = "Vault.pauseAsset";
        selectors[5] = Vault.unpauseAsset.selector;
        selectorsNames[5] = "Vault.unpauseAsset";
        selectors[6] = Vault.pauseProtocol.selector;
        selectorsNames[6] = "Vault.pauseProtocol";
        selectors[7] = Vault.unpauseProtocol.selector;
        selectorsNames[7] = "Vault.unpauseProtocol";
        selectors[8] = Vault.setInsuranceFund.selector;
        selectorsNames[8] = "Vault.setInsuranceFund";
        selectors[9] = Vault.rescueERC20.selector;
        selectorsNames[9] = "Vault.rescueERC20";
        selectors[10] = bytes4(0);
        selectorsNames[10] = "Vault.upgrade";
        return (selectors, selectorsNames);
    }

    function buildFractionalReserveSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        string[] memory selectorsNames = new string[](5);
        selectors[0] = FractionalReserve.investAll.selector;
        selectorsNames[0] = "FractionalReserve.investAll";
        selectors[1] = FractionalReserve.divestAll.selector;
        selectorsNames[1] = "FractionalReserve.divestAll";
        selectors[2] = FractionalReserve.setFractionalReserveVault.selector;
        selectorsNames[2] = "FractionalReserve.setFractionalReserveVault";
        selectors[3] = FractionalReserve.setReserve.selector;
        selectorsNames[3] = "FractionalReserve.setReserve";
        selectors[4] = bytes4(0);
        selectorsNames[4] = "FractionalReserve.upgrade";
        return (selectors, selectorsNames);
    }

    function buildDebtTokenSelectors() internal pure returns (bytes4[] memory, string[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        string[] memory selectorsNames = new string[](3);
        selectors[0] = DebtToken.mint.selector;
        selectorsNames[0] = "DebtToken.mint";
        selectors[1] = DebtToken.burn.selector;
        selectorsNames[1] = "DebtToken.burn";
        selectors[2] = bytes4(0);
        selectorsNames[2] = "DebtToken.upgrade";
        return (selectors, selectorsNames);
    }

    function checkRoles(
        bytes4[] memory selectors,
        string[] memory selectorsNames,
        address contractAddress,
        AccessControl _accessControl
    ) internal view {
        for (uint256 i = 0; i < selectors.length; i++) {
            bytes32 role = _accessControl.role(selectors[i], contractAddress);
            uint256 memberCount = _accessControl.getRoleMemberCount(role);
            if (memberCount == 0) {
                console.log("No admins for role", selectorsNames[i]);
                continue;
            }
            for (uint256 j = 0; j < memberCount; j++) {
                address member = _accessControl.getRoleMember(role, j);
                console.log(selectorsNames[i], member);
            }
        }
    }
}
