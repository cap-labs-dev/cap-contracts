// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { SymbioticNetworkAdapterConfig } from "../../contracts/deploy/interfaces/SymbioticsDeployConfigs.sol";
import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";
import { FeeReceiver } from "../../contracts/feeReceiver/FeeReceiver.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";
import { PriceOracle } from "../../contracts/oracle/PriceOracle.sol";
import { RateOracle } from "../../contracts/oracle/RateOracle.sol";
import { VaultAdapter } from "../../contracts/oracle/libraries/VaultAdapter.sol";
import { Wrapper } from "../../contracts/token/Wrapper.sol";
import { FractionalReserve } from "../../contracts/vault/FractionalReserve.sol";
import { Minter } from "../../contracts/vault/Minter.sol";
import { Vault } from "../../contracts/vault/Vault.sol";
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

contract CheckAccess is Script, InfraConfigSerializer, VaultConfigSerializer, SymbioticAdapterConfigSerializer {
    using Strings for address;

    InfraConfig infra;
    VaultConfig vaultConfig;
    SymbioticNetworkAdapterConfig symbioticAdapter;
    AccessControl accessControl;

    address[] devEoas = [0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52];

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
        NamedSelector({ selector: SymbioticNetwork.registerMiddleware.selector, name: "Network.registerMiddleware" }),
        NamedSelector({ selector: SymbioticNetwork.registerVault.selector, name: "Network.registerVault" }),
        NamedSelector({
            selector: SymbioticNetworkMiddleware.registerAgent.selector,
            name: "NetworkMiddleware.registerAgent"
        }),
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
        NamedSelector({ selector: Lender.addAsset.selector, name: "Lender.addAsset" }),
        NamedSelector({ selector: Lender.removeAsset.selector, name: "Lender.removeAsset" }),
        NamedSelector({ selector: Lender.pauseAsset.selector, name: "Lender.pauseAsset" }),
        NamedSelector({ selector: Lender.setInterestReceiver.selector, name: "Lender.setInterestReceiver" }),
        NamedSelector({ selector: Lender.setMinBorrow.selector, name: "Lender.setMinBorrow" }),
        NamedSelector({ selector: Lender.setGrace.selector, name: "Lender.setGrace" }),
        NamedSelector({ selector: Lender.setExpiry.selector, name: "Lender.setExpiry" }),
        NamedSelector({ selector: Lender.setBonusCap.selector, name: "Lender.setBonusCap" }),
        NamedSelector({ selector: Lender.liquidate.selector, name: "Lender.liquidate" }),
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
        (,, infra) = _readInfraConfig();
        vaultConfig = _readVaultConfig("cUSD");
        accessControl = AccessControl(infra.accessControl);

        namedContracts = [
            NamedContract({ contractAddress: infra.delegation, name: "Delegation" }),
            NamedContract({ contractAddress: infra.lender, name: "Lender" }),
            NamedContract({ contractAddress: infra.oracle, name: "Oracle" }),
            NamedContract({ contractAddress: infra.accessControl, name: "Access Control" }),
            NamedContract({ contractAddress: symbioticAdapter.network, name: "Network" }),
            NamedContract({ contractAddress: symbioticAdapter.networkMiddleware, name: "Network Middleware" }),
            NamedContract({ contractAddress: vaultConfig.feeAuction, name: "Fee Auction (cUSD)" }),
            NamedContract({ contractAddress: vaultConfig.feeReceiver, name: "Fee Receiver (cUSD)" }),
            NamedContract({ contractAddress: vaultConfig.capToken, name: "Vault (cUSD)" }),
            NamedContract({ contractAddress: vaultConfig.stakedCapToken, name: "Staked Vault (cUSD)" })
        ];
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

        vm.startBroadcast();
        for (uint256 i = 0; i < namedContracts.length; i++) {
            console.log("Checking Access for", namedContracts[i].name, "Contract...");
            address contractAddress = namedContracts[i].contractAddress;
            checkAllRoles(contractAddress);
            console.log("");
        }
        vm.stopBroadcast();
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
                return namedContracts[i].name;
            }
        }

        for (uint256 i = 0; i < devEoas.length; i++) {
            if (devEoas[i] == _address) {
                return unicode"🚨 Dev EOA 🚨";
            }
        }
        return _address.toHexString();
    }
}
