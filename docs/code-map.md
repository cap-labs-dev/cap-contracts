# Code Map

This document provides a detailed map of the codebase structure, showing how the code is organized and the relationships between different modules.

## Project Structure Overview

```mermaid
graph TB
    subgraph "Root Directory"
        contracts[📁 contracts/]
        test[📁 test/]
        script[📁 script/]
        config[📁 config/]
        lib[📁 lib/]
    end
    
    subgraph "contracts/ Structure"
        access[📁 access/]
        vault[📁 vault/]
        lendingPool[📁 lendingPool/]
        delegation[📁 delegation/]
        oracle[📁 oracle/]
        token[📁 token/]
        feeReceiver[📁 feeReceiver/]
        feeAuction[📁 feeAuction/]
        interfaces[📁 interfaces/]
        storage[📁 storage/]
        zap[📁 zap/]
        deploy[📁 deploy/]
    end
    
    contracts --> access
    contracts --> vault
    contracts --> lendingPool
    contracts --> delegation
    contracts --> oracle
    contracts --> token
    contracts --> feeReceiver
    contracts --> feeAuction
    contracts --> interfaces
    contracts --> storage
    contracts --> zap
    contracts --> deploy
```

## Core Modules Breakdown

### 1. Vault Module (`contracts/vault/`)

```mermaid
graph TB
    subgraph "Vault Core"
        Vault[Vault.sol]
        Minter[Minter.sol]
        FractionalReserve[FractionalReserve.sol]
    end
    
    subgraph "Vault Libraries"
        VaultLogic[libraries/VaultLogic.sol]
        MinterLogic[libraries/MinterLogic.sol]
        VaultUtils[libraries/VaultUtils.sol]
    end
    
    subgraph "Storage"
        VaultStorage[../storage/VaultStorageUtils.sol]
        MinterStorage[../storage/MinterStorageUtils.sol]
    end
    
    Vault --> VaultLogic
    Vault --> VaultStorage
    Minter --> MinterLogic
    Minter --> MinterStorage
    FractionalReserve --> VaultUtils
```

**Key Files**:
- `Vault.sol` (281 lines) - Core vault contract for asset management
- `Minter.sol` (95 lines) - Pricing logic for mint/burn operations  
- `FractionalReserve.sol` (121 lines) - Reserve management for fractional backing
- `libraries/VaultLogic.sol` - Core vault operation implementations
- `libraries/MinterLogic.sol` - Fee calculation and pricing logic

### 2. Lending Pool Module (`contracts/lendingPool/`)

```mermaid
graph TB
    subgraph "Lending Core"
        Lender[Lender.sol]
    end
    
    subgraph "Lending Libraries"
        BorrowLogic[libraries/BorrowLogic.sol]
        LiquidationLogic[libraries/LiquidationLogic.sol]
        ViewLogic[libraries/ViewLogic.sol]
        ValidationLogic[libraries/ValidationLogic.sol]
        InterestLogic[libraries/InterestLogic.sol]
    end
    
    subgraph "Token Management"
        DebtToken[tokens/DebtToken.sol]
        ScaledToken[tokens/ScaledToken.sol]
    end
    
    subgraph "Configuration"
        AgentConfig[libraries/configuration/AgentConfiguration.sol]
    end
    
    Lender --> BorrowLogic
    Lender --> LiquidationLogic
    Lender --> ViewLogic
    Lender --> ValidationLogic
    Lender --> InterestLogic
    Lender --> DebtToken
    DebtToken --> ScaledToken
    Lender --> AgentConfig
```

**Key Files**:
- `Lender.sol` (335 lines) - Main lending contract
- `libraries/BorrowLogic.sol` - Borrow and repay implementations
- `libraries/LiquidationLogic.sol` - Liquidation process logic
- `libraries/ViewLogic.sol` - Health calculations and views
- `tokens/DebtToken.sol` - Interest-bearing debt tokens

### 3. Delegation Module (`contracts/delegation/`)

```mermaid
graph TB
    subgraph "Delegation Core"
        Delegation[Delegation.sol]
    end
    
    subgraph "Network Adapters"
        NetworkAdapter[NetworkAdapter.sol]
        SymbioticAdapter[adapters/SymbioticNetworkAdapter.sol]
    end
    
    subgraph "Middleware"
        NetworkMiddleware[middleware/NetworkMiddleware.sol]
        StakerRewards[middleware/StakerRewards.sol]
    end
    
    subgraph "Libraries"
        DelegationLogic[libraries/DelegationLogic.sol]
        SlashingLogic[libraries/SlashingLogic.sol]
    end
    
    Delegation --> DelegationLogic
    Delegation --> SlashingLogic
    Delegation --> NetworkAdapter
    NetworkAdapter --> SymbioticAdapter
    NetworkAdapter --> NetworkMiddleware
    NetworkMiddleware --> StakerRewards
```

**Key Files**:
- `Delegation.sol` - Core delegation management
- `adapters/SymbioticNetworkAdapter.sol` - Symbiotic protocol integration
- `middleware/NetworkMiddleware.sol` - Network middleware interface
- `middleware/StakerRewards.sol` - Reward distribution logic

### 4. Oracle Module (`contracts/oracle/`)

```mermaid
graph TB
    subgraph "Oracle Core"
        Oracle[Oracle.sol]
        PriceOracle[PriceOracle.sol]
        RateOracle[RateOracle.sol]
    end
    
    subgraph "Oracle Libraries"
        ChainlinkAdapter[libraries/ChainlinkAdapter.sol]
        AaveAdapter[libraries/AaveAdapter.sol]
        VaultAdapter[libraries/VaultAdapter.sol]
        CapTokenAdapter[libraries/CapTokenAdapter.sol]
    end
    
    subgraph "External Interfaces"
        ChainlinkInterface[../interfaces/IChainlink.sol]
        AaveInterface[../interfaces/IAaveDataProvider.sol]
    end
    
    Oracle --> PriceOracle
    Oracle --> RateOracle
    PriceOracle --> ChainlinkAdapter
    RateOracle --> AaveAdapter
    RateOracle --> VaultAdapter
    RateOracle --> CapTokenAdapter
    ChainlinkAdapter --> ChainlinkInterface
    AaveAdapter --> AaveInterface
```

**Key Files**:
- `Oracle.sol` (31 lines) - Main oracle aggregator
- `PriceOracle.sol` (114 lines) - Price feed management
- `RateOracle.sol` (114 lines) - Interest rate management
- `libraries/ChainlinkAdapter.sol` - Chainlink price feed adapter
- `libraries/AaveAdapter.sol` - Aave rate feed adapter

### 5. Token Module (`contracts/token/`)

```mermaid
graph TB
    subgraph "Core Tokens"
        CapToken[CapToken.sol]
        StakedCap[StakedCap.sol]
        L2Token[L2Token.sol]
    end
    
    subgraph "Cross-Chain Tokens"
        OFTPermit[OFTPermit.sol]
        OFTLockbox[OFTLockbox.sol]
    end
    
    subgraph "Token Standards"
        ERC20[OpenZeppelin ERC20]
        OFT[LayerZero OFT]
        ERC4626[OpenZeppelin ERC4626]
    end
    
    CapToken --> ERC20
    StakedCap --> ERC4626
    L2Token --> ERC20
    OFTPermit --> OFT
    OFTLockbox --> OFT
```

**Key Files**:
- `CapToken.sol` (40 lines) - Main vault token (extends Vault.sol)
- `StakedCap.sol` (129 lines) - Staking wrapper for fee rewards
- `L2Token.sol` (22 lines) - Layer 2 token implementation
- `OFTPermit.sol` (79 lines) - LayerZero OFT with permit functionality

### 6. Interface Layer (`contracts/interfaces/`)

```mermaid
graph TB
    subgraph "Core Interfaces"
        IVault[IVault.sol]
        ILender[ILender.sol]
        IDelegation[IDelegation.sol]
        IOracle[IOracle.sol]
    end
    
    subgraph "Component Interfaces"
        IMinter[IMinter.sol]
        IFeeReceiver[IFeeReceiver.sol]
        IFeeAuction[IFeeAuction.sol]
        IDebtToken[IDebtToken.sol]
    end
    
    subgraph "External Interfaces"
        IChainlink[IChainlink.sol]
        IAaveDataProvider[IAaveDataProvider.sol]
        INetworkMiddleware[INetworkMiddleware.sol]
    end
    
    subgraph "Utility Interfaces"
        IAccessControl[IAccessControl.sol]
        IUpgradeableBeacon[IUpgradeableBeacon.sol]
        IPriceOracle[IPriceOracle.sol]
        IRateOracle[IRateOracle.sol]
    end
```

## Cross-Module Dependencies

### Dependency Graph

```mermaid
graph TD
    subgraph "Layer 1: Infrastructure"
        Access[access/]
        Storage[storage/]
        Interfaces[interfaces/]
    end
    
    subgraph "Layer 2: Core Components"
        Oracle[oracle/]
        Token[token/]
    end
    
    subgraph "Layer 3: Business Logic"
        Vault[vault/]
        Delegation[delegation/]
    end
    
    subgraph "Layer 4: Advanced Features"
        LendingPool[lendingPool/]
        FeeManagement[feeReceiver/ + feeAuction/]
    end
    
    subgraph "Layer 5: Cross-Chain & Utils"
        Zap[zap/]
        Deploy[deploy/]
    end
    
    %% Dependencies
    Oracle --> Access
    Oracle --> Interfaces
    Token --> Access
    Token --> Interfaces
    
    Vault --> Oracle
    Vault --> Token
    Vault --> Access
    Vault --> Storage
    
    Delegation --> Oracle
    Delegation --> Access
    Delegation --> Interfaces
    
    LendingPool --> Vault
    LendingPool --> Delegation
    LendingPool --> Oracle
    LendingPool --> Token
    
    FeeManagement --> Vault
    FeeManagement --> Token
    FeeManagement --> Access
    
    Zap --> Vault
    Zap --> Token
    Deploy --> LendingPool
    Deploy --> FeeManagement
```

### Import Patterns

```mermaid
graph LR
    subgraph "Internal Imports"
        LocalInterfaces[../interfaces/]
        LocalLibraries[./libraries/]
        LocalStorage[../storage/]
        LocalAccess[../access/]
    end
    
    subgraph "External Dependencies"
        OpenZeppelin[@openzeppelin/contracts]
        LayerZero[@layerzerolabs/lz-evm-oapp-v2]
        Symbiotic[Symbiotic Protocol]
    end
    
    Contract[Contract.sol] --> LocalInterfaces
    Contract --> LocalLibraries
    Contract --> LocalStorage
    Contract --> LocalAccess
    Contract --> OpenZeppelin
    Contract --> LayerZero
    Contract --> Symbiotic
```

## Testing Structure (`test/`)

```mermaid
graph TB
    subgraph "Test Categories"
        UnitTests[📁 Unit Tests]
        IntegrationTests[📁 Integration Tests]
        InvariantTests[📁 Invariant Tests]
        ScenarioTests[📁 Scenario Tests]
        Mocks[📁 Mocks]
    end
    
    subgraph "Test Organization"
        VaultTests[vault/]
        LenderTests[lendingPool/]
        DelegationTests[delegation/]
        OracleTests[oracle/]
        FeeTests[fees/]
        DeployTests[deploy/]
    end
    
    subgraph "Test Infrastructure"
        TestBase[TestBase.sol]
        TestUtils[TestUtils.sol]
        MockContracts[mocks/]
        Fixtures[fixtures/]
    end
```

**Key Test Files**:
- `vault/Vault.t.sol` - Core vault functionality tests
- `vault/Vault.invariants.t.sol` - Vault invariant testing
- `lendingPool/Lender.t.sol` - Lending pool tests
- `lendingPool/Lender.invariants.t.sol` - Lending invariants
- `scenario/` - End-to-end scenario tests

## Deployment Structure (`script/` & `contracts/deploy/`)

```mermaid
graph TB
    subgraph "Deployment Scripts"
        MainnetDeploy[script/DeployMainnet.s.sol]
        TestnetDeploy[script/DeployTestnet.s.sol]
        L2Deploy[script/DeployL2.s.sol]
    end
    
    subgraph "Deploy Infrastructure"
        DeployService[contracts/deploy/service/]
        DeployUtils[contracts/deploy/utils/]
        DeployConfigs[contracts/deploy/interfaces/]
    end
    
    subgraph "Deploy Services"
        DeployInfra[DeployInfra.sol]
        DeployVault[DeployVault.sol]
        DeployImplems[DeployImplems.sol]
        ConfigureAccess[ConfigureAccessControl.sol]
    end
    
    MainnetDeploy --> DeployService
    TestnetDeploy --> DeployService
    L2Deploy --> DeployService
    
    DeployService --> DeployInfra
    DeployService --> DeployVault
    DeployService --> DeployImplems
    DeployService --> ConfigureAccess
```

## Storage Layout (`contracts/storage/`)

```mermaid
graph TB
    subgraph "Storage Utils"
        VaultStorage[VaultStorageUtils.sol]
        LenderStorage[LenderStorageUtils.sol]
        DelegationStorage[DelegationStorageUtils.sol]
        OracleStorage[OracleStorageUtils.sol]
    end
    
    subgraph "ERC-7201 Namespaces"
        VaultNS["cap.storage.Vault"]
        LenderNS["cap.storage.Lender"]
        DelegationNS["cap.storage.Delegation"]
        OracleNS["cap.storage.Oracle"]
    end
    
    VaultStorage --> VaultNS
    LenderStorage --> LenderNS
    DelegationStorage --> DelegationNS
    OracleStorage --> OracleNS
```

## Build & Configuration

### Foundry Configuration (`foundry.toml`)
- **Source**: `contracts/`
- **Test**: `test/`
- **Script**: `script/`
- **Libraries**: `lib/`
- **Solidity Version**: `^0.8.28`
- **Optimizer**: Enabled with 200 runs

### Key Dependencies (`lib/`)
- **OpenZeppelin Contracts**: Core contract primitives
- **LayerZero V2**: Cross-chain messaging
- **Forge Standard Library**: Testing utilities
- **Symbiotic Core**: Restaking infrastructure

### Configuration Files
- `remappings.txt` - Import path mappings
- `gambit.config.json` - Mutation testing configuration
- `slither.config.json` - Static analysis configuration
- `lefthook.yml` - Git hooks configuration

## Code Quality & Security

### Static Analysis Tools
1. **Slither** - Vulnerability detection
2. **Mythril** - Security analysis
3. **Gambit** - Mutation testing
4. **Solhint** - Linting

### Testing Strategy
1. **Unit Tests** - Individual function testing
2. **Integration Tests** - Cross-contract interactions
3. **Invariant Tests** - Property-based testing
4. **Scenario Tests** - End-to-end user journeys
5. **Fuzzing** - Edge case discovery

### Gas Optimization
- Efficient storage layouts using ERC-7201
- Packed structs for reduced storage costs
- Optimized loop patterns
- Minimal external calls
- Cache storage reads

### Upgradeability Patterns
- UUPS proxy pattern for core contracts
- Storage gap preservation
- Version-aware initialization
- Admin-controlled upgrades with timelock

This code map provides developers with a comprehensive understanding of how the Cap Protocol codebase is structured and organized, making it easier to navigate and contribute to the project. 