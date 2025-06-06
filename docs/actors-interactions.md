# Actors and Interactions

This document describes all the actors in the Cap Protocol system and their possible interactions.

## System Actors Overview

```mermaid
graph TB
    subgraph "External Actors"
        Users[Regular Users]
        Agents[Agents/Operators]
        Restakers[Restakers/Delegators]
        Liquidators[Liquidators]
        Arbitrageurs[Arbitrageurs]
    end
    
    subgraph "Protocol Actors"
        Admins[Protocol Admins]
        Oracle[Oracle Keepers]
        Networks[Symbiotic Networks]
    end
    
    subgraph "System Components"
        Vault[Vault System]
        Lender[Lending Pool]
        Delegation[Delegation Layer]
        FeeSystem[Fee System]
    end
    
    %% External actor interactions
    Users --> Vault
    Agents --> Lender
    Restakers --> Networks
    Networks --> Delegation
    Liquidators --> Lender
    Arbitrageurs --> FeeSystem
    
    %% Protocol actor interactions
    Admins --> Vault
    Admins --> Lender
    Admins --> Delegation
    Oracle --> Vault
    Oracle --> Lender
```

## Actor Categories

### 1. Regular Users (Liquidity Providers)

**Role**: Provide liquidity to earn yield on their assets

```mermaid
graph LR
    User[Regular User] --> |deposit assets| Vault
    Vault --> |mint cTokens| User
    User --> |burn cTokens| Vault
    Vault --> |withdraw assets| User
    
    subgraph "User Actions"
        A[mint() - Deposit assets for cTokens]
        B[burn() - Redeem specific asset]
        C[redeem() - Redeem bundle of assets]
        D[stake() - Stake cTokens for rewards]
    end
```

**Possible Interactions**:
- `mint(asset, amount, receiver, deadline)` - Deposit assets to receive Cap tokens
- `burn(asset, amountIn, minAmountOut, receiver, deadline)` - Burn Cap tokens for specific asset
- `redeem(amountIn, minAmountsOut, receiver, deadline)` - Burn Cap tokens for bundle of assets
- `stake(amount)` - Stake Cap tokens in StakedCap for fee rewards
- `unstake(amount)` - Unstake with cooldown period
- `claimRewards()` - Claim accumulated fee rewards

### 2. Agents/Operators (Borrowers)

**Role**: Provide services to restaking networks and borrow against delegated stake

```mermaid
graph TB
    Agent[Agent/Operator] --> |register| Networks[Symbiotic Networks]
    Networks --> |delegate stake| Agent
    Agent --> |borrow assets| Lender
    Lender --> |check coverage| Delegation
    Delegation --> |validate LTV| Agent
    
    subgraph "Agent Lifecycle"
        A[Register with network]
        B[Receive delegated stake]
        C[Borrow against collateral]
        D[Provide network services]
        E[Repay loans]
        F[Risk liquidation if unhealthy]
    end
```

**Possible Interactions**:
- `borrow(asset, amount, receiver)` - Borrow assets against delegated collateral
- `repay(asset, amount, agent)` - Repay borrowed assets
- `realizeRestakerInterest(agent, asset)` - Realize accrued interest
- Network registration and opt-in operations
- Delegation management through Symbiotic networks

**Risk Profile**:
- Must maintain health ratio above liquidation threshold
- Subject to slashing if network misbehaves
- Restaker interest accrues on borrowed amounts

### 3. Restakers/Delegators

**Role**: Stake ETH/LSTs to back agents and earn restaking rewards

```mermaid
graph TB
    Restaker[Restaker] --> |stake assets| SymbioticVault[Symbiotic Vault]
    SymbioticVault --> |delegate| Agent[Agent/Operator]
    Agent --> |provide security| Networks[Active Validation Services]
    Networks --> |rewards| Restaker
    
    subgraph "Restaker Flow"
        A[Deposit ETH/LSTs]
        B[Choose operators to delegate to]
        C[Earn staking rewards]
        D[Bear slashing risk]
        E[Withdraw with unbonding period]
    end
```

**Possible Interactions**:
- Deposit assets into Symbiotic vaults
- Delegate to agents/operators  
- Claim restaking rewards
- Withdraw stake (subject to unbonding periods)
- Bear slashing risk for agent misbehavior

### 4. Liquidators

**Role**: Maintain system health by liquidating unhealthy agents

```mermaid
sequenceDiagram
    participant L as Liquidator
    participant Lender
    participant Agent
    participant Delegation
    participant Network
    
    L->>Lender: initiateLiquidation(agent)
    Note over Lender: Grace period starts (1 hour)
    L->>Lender: liquidate(agent, asset, amount)
    Lender->>Delegation: slash(agent, liquidator, usdValue)
    Delegation->>Network: slash(operator, amount)
    Network->>L: transfer slashed collateral + bonus
```

**Possible Interactions**:
- `initiateLiquidation(agent)` - Start liquidation process for unhealthy agent
- `cancelLiquidation(agent)` - Cancel if agent becomes healthy
- `liquidate(agent, asset, amount)` - Execute liquidation after grace period
- Monitor agent health ratios
- Receive liquidation bonuses (up to 10% bonus cap)

**Economic Incentives**:
- Liquidation bonus for maintaining system health
- Gas costs offset by bonus
- Competitive liquidation environment

### 5. Arbitrageurs

**Role**: Maintain efficient markets and participate in fee auctions

```mermaid
graph LR
    Arbitrageur[Arbitrageur] --> |monitor prices| Markets[Secondary Markets]
    Arbitrageur --> |bid in auctions| FeeAuction[Fee Auction]
    FeeAuction --> |distribute fees| StakedCap[Staked Cap Holders]
    
    subgraph "Arbitrage Opportunities"
        A[Cap token price deviations]
        B[Fee auction arbitrage]
        C[Cross-chain price differences]
    end
```

**Possible Interactions**:
- Monitor Cap token prices across DEXs
- Participate in fee auctions
- Cross-chain arbitrage via LayerZero
- MEV opportunities around liquidations

### 6. Protocol Admins

**Role**: Manage protocol configuration and parameters

```mermaid
graph TD
    subgraph "Admin Roles"
        AccessAdmin[Access Control Admin]
        OracleAdmin[Oracle Admin]
        LenderAdmin[Lender Admin]
        DelegationAdmin[Delegation Admin]
        VaultAdmin[Vault Config Admin]
        FeeAdmin[Fee Auction Admin]
    end
    
    AccessAdmin --> |grant/revoke roles| AllContracts[All Contracts]
    OracleAdmin --> |price/rate feeds| Oracle[Oracle System]
    LenderAdmin --> |asset management| Lender[Lending Pool]
    DelegationAdmin --> |agent management| Delegation[Delegation Layer]
    VaultAdmin --> |vault config| Vault[Vault System]
    FeeAdmin --> |auction params| FeeAuction[Fee Auction]
```

**Administrative Functions**:
- Asset management (add/remove/pause assets)
- Oracle configuration (price feeds, rate sources)
- Agent management (add/modify/remove agents)
- Fee structure updates
- Emergency pause controls
- Access control management

### 7. Oracle Keepers

**Role**: Maintain accurate price and rate feeds

```mermaid
graph TB
    Keeper[Oracle Keeper] --> |update prices| PriceOracle[Price Oracle]
    Keeper --> |update rates| RateOracle[Rate Oracle]
    
    subgraph "Oracle Data Sources"
        Chainlink[Chainlink Feeds]
        Aave[Aave Rate Oracles]
        External[External APIs]
    end
    
    Chainlink --> PriceOracle
    Aave --> RateOracle
    External --> RateOracle
```

**Responsibilities**:
- Price feed updates for all supported assets
- Benchmark rate updates
- Restaker rate management per agent
- Market oracle data maintenance
- Utilization index updates

## Actor Interaction Flows

### Complete User Journey: Vault Operations

```mermaid
sequenceDiagram
    participant U as User
    participant V as Vault
    participant M as Minter
    participant O as Oracle
    participant F as FeeReceiver
    participant S as StakedCap
    
    Note over U,S: Minting Flow
    U->>V: mint(USDC, 1000, user, deadline)
    V->>O: getPrice(USDC)
    V->>M: calculateMintAmount(USDC, 1000)
    V->>F: transfer mint fees
    V->>U: transfer 950 cUSD tokens
    
    Note over U,S: Staking Flow  
    U->>S: stake(950 cUSD)
    S->>S: start cooldown period
    
    Note over U,S: Fee Distribution
    F->>S: distribute fees to stakers
    U->>S: claimRewards()
```

### Complete Agent Journey: Borrowing Flow

```mermaid
sequenceDiagram
    participant A as Agent
    participant N as Network
    participant D as Delegation
    participant L as Lender
    participant V as Vault
    participant DT as DebtToken
    
    Note over A,DT: Setup Phase
    A->>N: registerAsOperator()
    A->>N: optInToNetwork()
    A->>D: addAgent(agent, network, ltv, threshold)
    
    Note over A,DT: Borrowing Phase
    A->>L: borrow(USDC, 500, agent)
    L->>D: coverage(agent)
    L->>L: validateHealth(agent)
    L->>V: borrow(USDC, 500, agent)
    L->>DT: mint(agent, 500)
    L->>D: setLastBorrow(agent)
```

### Complete Liquidation Flow

```mermaid
sequenceDiagram
    participant Liquidator
    participant Lender
    participant Agent
    participant Delegation
    participant Network
    participant Restakers
    
    Note over Liquidator,Restakers: Detection Phase
    Liquidator->>Lender: agent health < 1.0
    Liquidator->>Lender: initiateLiquidation(agent)
    Note over Lender: Grace period: 1 hour
    
    Note over Liquidator,Restakers: Liquidation Phase
    Liquidator->>Lender: liquidate(agent, USDC, 100)
    Lender->>Delegation: slash(agent, liquidator, $110)
    Delegation->>Network: slash(operator, $110)
    Network->>Restakers: slash delegated stake
    Network->>Liquidator: transfer $110 in slashed assets
```

## Actor Incentive Alignment

### Users (Liquidity Providers)
- **Earn**: Fee rewards from vault operations
- **Risk**: Smart contract risk, asset price volatility
- **Alignment**: Higher vault utilization = higher fees = higher rewards

### Agents/Operators  
- **Earn**: Network service rewards, leverage on operations
- **Risk**: Slashing risk, liquidation risk, restaker interest costs
- **Alignment**: Maintain healthy positions to avoid liquidation

### Restakers
- **Earn**: Staking rewards, restaker interest from agents
- **Risk**: Slashing risk from agent misbehavior
- **Alignment**: Delegate to reliable agents with good track records

### Liquidators
- **Earn**: Liquidation bonuses (up to 10%)
- **Risk**: Gas costs, timing risk
- **Alignment**: Maintain system health by liquidating unhealthy positions

### Protocol
- **Revenue**: Fees from minting, borrowing, and cross-chain operations
- **Costs**: Oracle maintenance, governance overhead
- **Alignment**: Growth in TVL and utilization drives fee revenue

## Risk Management

### System-wide Safeguards
1. **Grace Periods**: 1-hour grace period before liquidations
2. **Emergency Liquidations**: Immediate liquidation below 0.7 health ratio
3. **Pause Mechanisms**: Asset and protocol-level pause controls
4. **LTV Buffers**: 5% buffer between LTV and liquidation thresholds
5. **Bonus Caps**: Maximum 10% liquidation bonus to prevent over-incentivization

### Agent Risk Controls
1. **Health Monitoring**: Continuous health ratio tracking
2. **Utilization Limits**: Maximum borrowing based on delegated collateral  
3. **Interest Accrual**: Automatic interest calculation and realization
4. **Network Validation**: Only whitelisted networks can back agents
5. **Minimum Borrow**: Minimum borrow amounts to prevent dust positions 