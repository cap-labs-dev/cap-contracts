// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { EigenAgentManager } from "../../contracts/delegation/providers/eigenlayer/EigenAgentManager.sol";
import { EigenServiceManager } from "../../contracts/delegation/providers/eigenlayer/EigenServiceManager.sol";
import { SymbioticAgentManager } from "../../contracts/delegation/providers/symbiotic/SymbioticAgentManager.sol";
import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { EigenConfig } from "../../contracts/deploy/interfaces/EigenDeployConfig.sol";
import { SymbioticNetworkAdapterConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";

import { EigenAddressbook, EigenUtils } from "../../contracts/deploy/utils/EigenUtils.sol";
import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";
import { FeeReceiver } from "../../contracts/feeReceiver/FeeReceiver.sol";
import { CapInterestHarvester } from "../../contracts/gelato/CapInterestHarvester.sol";
import { CapSweeper } from "../../contracts/gelato/CapSweeper.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";
import { PriceOracle } from "../../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../../contracts/oracle/RateOracle.sol";
import { CapChainlinkPoRAddressList } from "../../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { VaultAdapter } from "../../contracts/oracle/libraries/VaultAdapter.sol";
import { Wrapper } from "../../contracts/token/Wrapper.sol";
import { FractionalReserve } from "../../contracts/vault/FractionalReserve.sol";
import { Minter } from "../../contracts/vault/Minter.sol";
import { Vault } from "../../contracts/vault/Vault.sol";
import { EigenAdapterConfigSerializer } from "../config/EigenAdapterConfigSerializer.sol";
import { InfraConfigSerializer } from "../config/InfraConfigSerializer.sol";
import { SymbioticAdapterConfigSerializer } from "../config/SymbioticAdapterConfigSerializer.sol";
import { VaultConfigSerializer } from "../config/VaultConfigSerializer.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

struct NamedSelector {
    bytes4 selector;
    string name;
}

struct NamedContract {
    address contractAddress;
    string name;
}

contract CheckAccess is
    Script,
    InfraConfigSerializer,
    VaultConfigSerializer,
    SymbioticAdapterConfigSerializer,
    EigenAdapterConfigSerializer,
    EigenUtils
{
    using Strings for address;

    EigenAddressbook eigenAb;
    InfraConfig infra;
    VaultConfig vaultConfig;
    SymbioticNetworkAdapterConfig symbioticAdapter;
    EigenConfig eigenAdapter;
    AccessControl accessControl;

    address[] devEoas = [0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52];
    address msig = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);
    address timelock = address(0xD8236031d8279d82E615aF2BFab5FC0127A329ab);
    address gelato = address(0xe84E4337c382cC8Ed57c6FB12919270228B6B7A3);
    address balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    NamedSelector[] namedSelectors = [
        NamedSelector({ selector: AccessControl.grantAccess.selector, name: "AccessControl.grantAccess" }),
        NamedSelector({ selector: AccessControl.revokeAccess.selector, name: "AccessControl.revokeAccess" }),
        NamedSelector({ selector: AccessControl.checkAccess.selector, name: "AccessControl.checkAccess" }),
        NamedSelector({ selector: Delegation.slash.selector, name: "Delegation.slash" }),
        NamedSelector({ selector: Delegation.setLastBorrow.selector, name: "Delegation.setLastBorrow" }),
        NamedSelector({ selector: Delegation.addAgent.selector, name: "Delegation.addAgent" }),
        NamedSelector({ selector: Delegation.modifyAgent.selector, name: "Delegation.modifyAgent" }),
        NamedSelector({ selector: Delegation.registerNetwork.selector, name: "Delegation.registerNetwork" }),
        NamedSelector({ selector: Delegation.setLtvBuffer.selector, name: "Delegation.setLtvBuffer" }),
        NamedSelector({ selector: Delegation.setFeeRecipient.selector, name: "Delegation.setFeeRecipient" }),
        NamedSelector({ selector: EigenAgentManager.addEigenAgent.selector, name: "EigenAgentManager.addEigenAgent" }),
        NamedSelector({ selector: EigenAgentManager.setRestakerRate.selector, name: "EigenAgentManager.setRestakerRate" }),
        NamedSelector({ selector: EigenServiceManager.slash.selector, name: "EigenServiceManager.slash" }),
        NamedSelector({
            selector: EigenServiceManager.distributeRewards.selector,
            name: "EigenServiceManager.distributeRewards"
        }),
        NamedSelector({
            selector: EigenServiceManager.registerOperator.selector,
            name: "EigenServiceManager.registerOperator"
        }),
        NamedSelector({
            selector: EigenServiceManager.registerStrategy.selector,
            name: "EigenServiceManager.registerStrategy"
        }),
        NamedSelector({
            selector: EigenServiceManager.updateAVSMetadataURI.selector,
            name: "EigenServiceManager.updateAVSMetadataURI"
        }),
        NamedSelector({
            selector: EigenServiceManager.setEpochsBetweenDistributions.selector,
            name: "EigenServiceManager.setEpochsBetweenDistributions"
        }),
        NamedSelector({
            selector: EigenServiceManager.upgradeEigenOperatorImplementation.selector,
            name: "EigenServiceManager.upgradeEigenOperatorImplementation"
        }),
        NamedSelector({ selector: SymbioticAgentManager.addAgent.selector, name: "AgentManager.addAgent" }),
        NamedSelector({ selector: SymbioticAgentManager.setRestakerRate.selector, name: "AgentManager.addAgent" }),
        NamedSelector({ selector: SymbioticNetwork.registerVault.selector, name: "Network.registerVault" }),
        NamedSelector({
            selector: SymbioticNetworkMiddleware.registerVault.selector,
            name: "NetworkMiddleware.registerVault"
        }),
        NamedSelector({
            selector: SymbioticNetworkMiddleware.setFeeAllowed.selector,
            name: "NetworkMiddleware.setFeeAllowed"
        }),
        NamedSelector({ selector: SymbioticNetworkMiddleware.slash.selector, name: "NetworkMiddleware.slash" }),
        NamedSelector({
            selector: SymbioticNetworkMiddleware.distributeRewards.selector,
            name: "NetworkMiddleware.distributeRewards"
        }),
        NamedSelector({ selector: FeeAuction.setStartPrice.selector, name: "FeeAuction.setStartPrice" }),
        NamedSelector({ selector: FeeAuction.setDuration.selector, name: "FeeAuction.setDuration" }),
        NamedSelector({ selector: FeeAuction.setMinStartPrice.selector, name: "FeeAuction.setMinStartPrice" }),
        NamedSelector({ selector: FeeAuction.setPaymentToken.selector, name: "FeeAuction.setPaymentToken" }),
        NamedSelector({ selector: FeeReceiver.setCapToken.selector, name: "FeeReceiver.setCapToken" }),
        NamedSelector({ selector: FeeReceiver.setStakedCapToken.selector, name: "FeeReceiver.setStakedCapToken" }),
        NamedSelector({
            selector: FeeReceiver.setProtocolFeePercentage.selector,
            name: "FeeReceiver.setProtocolFeePercentage"
        }),
        NamedSelector({ selector: FeeReceiver.setProtocolFeeReceiver.selector, name: "FeeReceiver.setProtocolFeeReceiver" }),
        NamedSelector({
            selector: CapInterestHarvester.harvestInterest.selector,
            name: "CapInterestHarvester.harvestInterest"
        }),
        NamedSelector({
            selector: CapInterestHarvester.receiveFlashLoan.selector,
            name: "CapInterestHarvester.receiveFlashLoan"
        }),
        NamedSelector({
            selector: CapInterestHarvester.setExcessReceiver.selector,
            name: "CapInterestHarvester.setExcessReceiver"
        }),
        NamedSelector({ selector: CapSweeper.sweep.selector, name: "CapSweeper.sweep" }),
        NamedSelector({ selector: CapSweeper.setSweepInterval.selector, name: "CapSweeper.setSweepInterval" }),
        NamedSelector({ selector: CapSweeper.setMinSweepAmount.selector, name: "CapSweeper.setMinSweepAmount" }),
        NamedSelector({ selector: Lender.addAsset.selector, name: "Lender.addAsset" }),
        NamedSelector({ selector: Lender.removeAsset.selector, name: "Lender.removeAsset" }),
        NamedSelector({ selector: Lender.pauseAsset.selector, name: "Lender.pauseAsset" }),
        NamedSelector({ selector: Lender.setInterestReceiver.selector, name: "Lender.setInterestReceiver" }),
        NamedSelector({ selector: Lender.setMinBorrow.selector, name: "Lender.setMinBorrow" }),
        NamedSelector({ selector: Lender.setGrace.selector, name: "Lender.setGrace" }),
        NamedSelector({ selector: Lender.setExpiry.selector, name: "Lender.setExpiry" }),
        NamedSelector({ selector: Lender.setBonusCap.selector, name: "Lender.setBonusCap" }),
        NamedSelector({ selector: DebtToken.mint.selector, name: "DebtToken.mint" }),
        NamedSelector({ selector: DebtToken.burn.selector, name: "DebtToken.burn" }),
        NamedSelector({ selector: PriceOracle.setPriceOracleData.selector, name: "PriceOracle.setPriceOracleData" }),
        NamedSelector({
            selector: PriceOracle.setPriceBackupOracleData.selector,
            name: "PriceOracle.setPriceBackupOracleData"
        }),
        NamedSelector({ selector: PriceOracle.setStaleness.selector, name: "PriceOracle.setStaleness" }),
        NamedSelector({ selector: RateOracle.setMarketOracleData.selector, name: "RateOracle.setMarketOracleData" }),
        NamedSelector({ selector: RateOracle.setUtilizationOracleData.selector, name: "RateOracle.setUtilizationOracleData" }),
        NamedSelector({ selector: RateOracle.setBenchmarkRate.selector, name: "RateOracle.setBenchmarkRate" }),
        NamedSelector({ selector: RateOracle.setRestakerRate.selector, name: "RateOracle.setRestakerRate" }),
        NamedSelector({
            selector: CapChainlinkPoRAddressList.addTokenPriceOracle.selector,
            name: "CapChainlinkPoRAddressList.addTokenPriceOracle"
        }),
        NamedSelector({ selector: VaultAdapter.setSlopes.selector, name: "VaultAdapter.setSlopes" }),
        NamedSelector({ selector: VaultAdapter.setLimits.selector, name: "VaultAdapter.setLimits" }),
        NamedSelector({ selector: Wrapper.setDonationReceiver.selector, name: "Wrapper.setDonationReceiver" }),
        NamedSelector({ selector: FractionalReserve.investAll.selector, name: "FractionalReserve.investAll" }),
        NamedSelector({ selector: FractionalReserve.divestAll.selector, name: "FractionalReserve.divestAll" }),
        NamedSelector({
            selector: FractionalReserve.setFractionalReserveVault.selector,
            name: "FractionalReserve.setFractionalReserveVault"
        }),
        NamedSelector({ selector: FractionalReserve.setReserve.selector, name: "FractionalReserve.setReserve" }),
        NamedSelector({ selector: Minter.setFeeData.selector, name: "Minter.setFeeData" }),
        NamedSelector({ selector: Minter.setRedeemFee.selector, name: "Minter.setRedeemFee" }),
        NamedSelector({ selector: Minter.setWhitelist.selector, name: "Minter.setWhitelist" }),
        NamedSelector({ selector: Vault.borrow.selector, name: "Vault.borrow" }),
        NamedSelector({ selector: Vault.repay.selector, name: "Vault.repay" }),
        NamedSelector({ selector: Vault.addAsset.selector, name: "Vault.addAsset" }),
        NamedSelector({ selector: Vault.removeAsset.selector, name: "Vault.removeAsset" }),
        NamedSelector({ selector: Vault.pauseAsset.selector, name: "Vault.pauseAsset" }),
        NamedSelector({ selector: Vault.unpauseAsset.selector, name: "Vault.unpauseAsset" }),
        NamedSelector({ selector: Vault.pauseProtocol.selector, name: "Vault.pauseProtocol" }),
        NamedSelector({ selector: Vault.unpauseProtocol.selector, name: "Vault.unpauseProtocol" }),
        NamedSelector({ selector: Vault.setInsuranceFund.selector, name: "Vault.setInsuranceFund" }),
        NamedSelector({ selector: Vault.rescueERC20.selector, name: "Vault.rescueERC20" }),
        NamedSelector({ selector: bytes4(0), name: "Proxy.upgrade" })
    ];

    NamedContract[] namedContracts;

    function run() external {
        eigenAb = _getEigenAddressbook();
        (,, infra) = _readInfraConfig();
        (, symbioticAdapter) = _readSymbioticConfig();
        (, eigenAdapter) = _readEigenConfig();
        accessControl = AccessControl(infra.accessControl);

        namedContracts = [
            NamedContract({ contractAddress: infra.delegation, name: "Delegation" }),
            NamedContract({ contractAddress: infra.lender, name: "Lender" }),
            NamedContract({ contractAddress: infra.oracle, name: "Oracle" }),
            NamedContract({ contractAddress: infra.accessControl, name: "Access Control" }),
            NamedContract({ contractAddress: infra.chainlinkPoRAddressList, name: "Chainlink PoR Address List" }),
            NamedContract({ contractAddress: infra.gelatoHarvester, name: "Gelato Harvester" }),
            NamedContract({ contractAddress: infra.gelatoSweeper, name: "Gelato Sweeper" }),
            NamedContract({ contractAddress: symbioticAdapter.network, name: "Network" }),
            NamedContract({ contractAddress: symbioticAdapter.networkMiddleware, name: "Network Middleware" }),
            NamedContract({ contractAddress: symbioticAdapter.agentManager, name: "Agent Manager" }),
            NamedContract({ contractAddress: eigenAdapter.agentManager, name: "Eigen Agent Manager" }),
            NamedContract({ contractAddress: eigenAdapter.eigenServiceManager, name: "Eigen Service Manager" })
        ];

        string[1] memory capTokenSymbols = ["cUSD"];
        for (uint256 i = 0; i < capTokenSymbols.length; i++) {
            string memory symbol = capTokenSymbols[i];
            _addVault(symbol);
        }

        vm.startBroadcast();
        for (uint256 i = 0; i < namedContracts.length; i++) {
            console.log("Checking Access for", namedContracts[i].name, "Contract...");
            address contractAddress = namedContracts[i].contractAddress;
            checkAllRoles(contractAddress);
            console.log("");
        }

        console.log("Checking Access for AccessControl Contract...");
        // Check default admin role
        bytes32 role = 0x0000000000000000000000000000000000000000000000000000000000000000;
        uint256 memberCount = accessControl.getRoleMemberCount(role);
        for (uint256 j = 0; j < memberCount; j++) {
            address member = accessControl.getRoleMember(role, j);
            console.log("Default Admin Role", labelledAddress(member));
            console.log("");
        }
        vm.stopBroadcast();
    }

    function _addVault(string memory symbol) internal {
        vaultConfig = _readVaultConfig(symbol);

        namedContracts.push(
            NamedContract({ contractAddress: vaultConfig.feeAuction, name: string.concat("Fee Auction (", symbol, ")") })
        );
        namedContracts.push(
            NamedContract({
                contractAddress: vaultConfig.feeReceiver,
                name: string.concat("Fee Receiver (", symbol, ")")
            })
        );
        namedContracts.push(
            NamedContract({ contractAddress: vaultConfig.capToken, name: string.concat("Vault (", symbol, ")") })
        );
        namedContracts.push(
            NamedContract({
                contractAddress: vaultConfig.stakedCapToken,
                name: string.concat("Staked Vault (", symbol, ")")
            })
        );

        for (uint256 i = 0; i < vaultConfig.debtTokens.length; i++) {
            address debtToken = vaultConfig.debtTokens[i];
            string memory debtTokenName = IERC20Metadata(debtToken).name();
            namedContracts.push(
                NamedContract({
                    contractAddress: debtToken,
                    name: string.concat("Debt Token ", Strings.toString(i), " of cUSD vault (", debtTokenName, ")")
                })
            );
        }
    }

    function checkAllRoles(address contractAddress) internal view {
        for (uint256 i = 0; i < namedSelectors.length; i++) {
            NamedSelector memory namedSelector = namedSelectors[i];
            bytes32 role = accessControl.role(namedSelector.selector, contractAddress);
            uint256 memberCount = accessControl.getRoleMemberCount(role);
            for (uint256 j = 0; j < memberCount; j++) {
                address member = accessControl.getRoleMember(role, j);
                console.log(namedSelector.name, labelledAddress(member));
            }
        }
    }

    function labelledAddress(address _address) internal view returns (string memory) {
        for (uint256 i = 0; i < namedContracts.length; i++) {
            if (namedContracts[i].contractAddress == _address) {
                return string.concat(unicode"✅", namedContracts[i].name, unicode"✅");
            }
        }

        if (eigenAb.eigenAddresses.allocationManager == _address) {
            return unicode"✅ Eigen Allocation Manager ✅";
        }

        for (uint256 i = 0; i < devEoas.length; i++) {
            if (devEoas[i] == _address) {
                return unicode"🚨 Dev EOA 🚨";
            }
        }

        if (msig == _address) {
            return unicode"✅ Dev MSIG ✅";
        }

        if (gelato == _address) {
            // unicode icecream emoji
            return unicode"🍦 Gelato 🍦";
        }

        if (balancerVault == _address) {
            return unicode"⚖️ Balancer ⚖️";
        }

        if (timelock == _address) {
            return unicode"🔒 Timelock 🔒";
        }

        return string.concat(unicode"🚨", _address.toHexString(), unicode"🚨");
    }
}
