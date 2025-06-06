# Contract Architecture

This document outlines the high-level architecture of the Cap Protocol, showing the main contract categories and their interactions.

## System Overview

```mermaid
graph TB
    subgraph "Core Infrastructure"
        AC[AccessControl]
        Oracle[Oracle System]
    end
    
    subgraph "Vault Layer"
        Vault[Vault/CapToken]
        StakedCap[StakedCap]
        Minter[Minter]
        FractionalReserve[FractionalReserve]
    end
    
    subgraph "Lending Layer"
        Lender[Lender]
        DebtToken[DebtToken]
        InterestLogic[Interest Logic]
    end
    
    subgraph "Delegation Layer"
        Delegation[Delegation]
        Networks[Symbiotic Networks]
        Agents[Operators/Agents]
    end
    
    subgraph "Fee Management"
        FeeReceiver[FeeReceiver]
        FeeAuction[FeeAuction]
    end
    
    subgraph "Cross-Chain"
        LZ[LayerZero Integration]
        OFTLockbox[OFT Lockbox]
        ZapComposer[Zap Composer]
    end
    
    %% Core connections
    AC --> Vault
    AC --> Lender
    AC --> Delegation
    AC --> FeeAuction
    
    Oracle --> Vault
    Oracle --> Lender
    Oracle --> Delegation
    
    %% Vault layer connections
    Vault --> Minter
    Vault --> FractionalReserve
    Vault --> StakedCap
    Vault --> FeeReceiver
    
    %% Lending connections
    Lender --> Vault
    Lender --> Delegation
    Lender --> DebtToken
    Lender --> FeeAuction
    
    %% Delegation connections
    Delegation --> Networks
    Networks --> Agents
    
    %% Fee flow
    FeeReceiver --> FeeAuction
    FeeAuction --> StakedCap
    
    %% Cross-chain
    Vault --> LZ
    StakedCap --> LZ
    LZ --> OFTLockbox
    LZ --> ZapComposer
```

## Core Contract Categories

### 1. Vault Layer
**Purpose**: Asset management and token issuance

```mermaid
classDiagram
    class Vault {
        +mint(asset, amount, receiver)
        +burn(asset, amount, receiver)
        +redeem(amount, receiver)
        +borrow(asset, amount, receiver)
        +repay(asset, amount)
        +totalSupplies(asset)
        +totalBorrows(asset)
        +utilization(asset)
    }
    
    class Minter {
        +calculateMintAmount(asset, amountIn)
        +calculateBurnAmount(asset, amountIn)
        +getFeeData(asset)
        +setFeeData(asset, feeData)
    }
    
    class FractionalReserve {
        +reserveRatio()
        +availableBalance(asset)
        +reserveBalance(asset)
    }
    
    class StakedCap {
        +stake(amount)
        +unstake(amount)
        +claimRewards()
        +cooldownPeriod()
    }
    
    Vault --> Minter : uses for pricing
    Vault --> FractionalReserve : manages reserves
    Vault --> StakedCap : fee distribution
```

### 2. Lending Layer
**Purpose**: Credit facilities and debt management

```mermaid
classDiagram
    class Lender {
        +borrow(asset, amount, receiver)
        +repay(asset, amount, agent)
        +liquidate(agent, asset, amount)
        +initiateLiquidation(agent)
        +agent(address) AgentData
        +maxBorrowable(agent, asset)
    }
    
    class DebtToken {
        +mint(to, amount)
        +burn(from, amount)
        +balanceOf(account)
        +scaledBalanceOf(account)
    }
    
    class InterestLogic {
        +calculateInterest(asset, timeElapsed)
        +realizeInterest(asset)
        +accruedRestakerInterest(agent, asset)
    }
    
    Lender --> DebtToken : manages debt
    Lender --> InterestLogic : calculates rates
    Lender --> Vault : borrows assets
    Lender --> Delegation : checks collateral
```

### 3. Delegation Layer
**Purpose**: Restaking infrastructure and slashing

```mermaid
classDiagram
    class Delegation {
        +addAgent(agent, network, ltv, threshold)
        +coverage(agent)
        +slashableCollateral(agent)
        +slash(agent, liquidator, amount)
        +setLastBorrow(agent)
    }
    
    class NetworkMiddleware {
        +registerOperator(operator)
        +optIn(vault)
        +delegate(operator, amount)
        +undelegate(operator, amount)
    }
    
    class Agent {
        +ltv()
        +liquidationThreshold()
        +lastBorrow()
        +network()
    }
    
    Delegation --> NetworkMiddleware : interfaces with
    Delegation --> Agent : manages
    NetworkMiddleware --> Agent : delegates to
```

### 4. Oracle System
**Purpose**: Price and rate discovery

```mermaid
classDiagram
    class Oracle {
        +getPrice(asset) price
        +getBenchmarkRate(asset) rate
        +getRestakerRate(agent, asset) rate
        +getUtilizationIndex(asset) index
    }
    
    class PriceOracle {
        +setPriceOracleData(asset, source)
        +latestAnswer(asset)
    }
    
    class RateOracle {
        +setBenchmarkRate(asset, rate)
        +setRestakerRate(agent, rate)
        +setMarketOracleData(asset, source)
    }
    
    Oracle --> PriceOracle : price feeds
    Oracle --> RateOracle : rate feeds
```

## Contract Interactions

### Vault Operations Flow
```mermaid
sequenceDiagram
    participant User
    participant Vault
    participant Minter
    participant Oracle
    participant FeeReceiver
    
    User->>Vault: mint(asset, amount)
    Vault->>Oracle: getPrice(asset)
    Vault->>Minter: calculateMintAmount(asset, amount)
    Vault->>Vault: updateUtilizationIndex(asset)
    Vault->>FeeReceiver: transfer fees
    Vault->>User: transfer capTokens
```

### Lending Operations Flow
```mermaid
sequenceDiagram
    participant Agent
    participant Lender
    participant Delegation
    participant Vault
    participant DebtToken
    
    Agent->>Lender: borrow(asset, amount)
    Lender->>Delegation: coverage(agent)
    Lender->>Lender: validateHealth(agent)
    Lender->>Vault: borrow(asset, amount, agent)
    Lender->>DebtToken: mint(agent, amount)
    Lender->>Delegation: setLastBorrow(agent)
```

### Liquidation Flow
```mermaid
sequenceDiagram
    participant Liquidator
    participant Lender
    participant Delegation
    participant NetworkMiddleware
    
    Liquidator->>Lender: initiateLiquidation(agent)
    Lender->>Lender: validateUnhealthy(agent)
    Note over Lender: Grace period starts
    
    Liquidator->>Lender: liquidate(agent, asset, amount)
    Lender->>Delegation: slash(agent, liquidator, usdValue)
    Delegation->>NetworkMiddleware: slash(operator, amount)
    NetworkMiddleware->>Liquidator: transfer slashed assets
```

## Access Control Architecture

```mermaid
graph TD
    subgraph "Access Control Roles"
        Admin[Access Control Admin]
        OracleAdmin[Oracle Admin]
        LenderAdmin[Lender Admin]
        DelegationAdmin[Delegation Admin]
        VaultAdmin[Vault Config Admin]
        FeeAdmin[Fee Auction Admin]
    end
    
    subgraph "Contract Permissions"
        Admin --> |manages all| AC[AccessControl]
        OracleAdmin --> |price/rate updates| Oracle
        LenderAdmin --> |asset config| Lender
        DelegationAdmin --> |agent management| Delegation
        VaultAdmin --> |vault config| Vault
        FeeAdmin --> |auction config| FeeAuction
    end
    
    subgraph "Cross-Contract Access"
        Lender --> |slash agents| Delegation
        Vault --> |borrow assets| Lender
        FeeAuction --> |receive fees| Vault
        Oracle --> |provide prices| Vault
        Oracle --> |provide rates| Lender
    end
```

## Upgradeability Pattern

```mermaid
graph TB
    subgraph "Proxy Pattern (UUPS)"
        Proxy[Proxy Contract]
        Implementation[Implementation Contract]
        Storage[Storage Slots]
    end
    
    subgraph "Upgrade Process"
        Admin[Admin]
        NewImpl[New Implementation]
    end
    
    Proxy --> |delegatecall| Implementation
    Proxy --> |persistent state| Storage
    Admin --> |upgrade newImplementation| Proxy
    Admin --> |deploy new version| NewImpl
    
    note1[All user calls go to Proxy]
    note2[Logic in Implementation]
    note3[State in Storage slots]
```

## Key Design Patterns

1. **UUPS Upgradeable**: All core contracts use OpenZeppelin's UUPS proxy pattern
2. **Access Control**: Role-based permissions with function-level granularity  
3. **Storage Slots**: ERC-7201 namespace storage to avoid collisions
4. **Modular Architecture**: Clear separation between vault, lending, delegation layers
5. **Oracle Abstraction**: Pluggable oracle sources for prices and rates
6. **Emergency Controls**: Pause mechanisms at asset and protocol levels 