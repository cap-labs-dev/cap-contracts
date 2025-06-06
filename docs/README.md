# Cap Protocol Documentation

This documentation provides comprehensive diagrams and schemas for the Cap Protocol smart contract architecture.

## Contents

1. [Contract Architecture](./contract-architecture.md) - High-level contract categories and their interactions
2. [Actors and Interactions](./actors-interactions.md) - System actors and their possible interactions
3. [Code Map](./code-map.md) - Detailed code structure and organization

## Overview

Cap Protocol is a decentralized lending protocol built on restaking infrastructure. It enables:

- **Vault Operations**: Minting and burning of Cap tokens backed by multiple assets
- **Lending/Borrowing**: Overcollateralized lending with delegation-backed credit
- **Delegation System**: Agents can borrow against delegated stake from restakers
- **Liquidation System**: Health-based liquidations with grace periods
- **Fee Management**: Dynamic fee structures and auction mechanisms
- **Oracle Integration**: Price and rate feeds for all operations

## Architecture Principles

The protocol follows a modular architecture with:
- **Upgradeable Proxies**: All core contracts are upgradeable using UUPS pattern
- **Access Control**: Role-based permissions system
- **Separation of Concerns**: Clear boundaries between vault, lending, delegation, and oracle modules
- **Interoperability**: LayerZero integration for cross-chain operations

## Key Components

- **Vault**: Core token issuance and asset management
- **Lender**: Credit facilities for agents
- **Delegation**: Staking and slashing mechanics
- **Oracle**: Price and rate discovery
- **Fee Management**: Revenue distribution and auctions 