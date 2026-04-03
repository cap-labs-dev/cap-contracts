// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeployEigenAdapter } from "./DeployEigenAdapter.sol";
import { DeploySymbioticNetworkAdapter } from "./DeploySymbioticNetworkAdapter.sol";

/// @dev Backwards-compatible wrapper to preserve existing imports.
/// Prefer inheriting `DeployEigenAdapter` and/or `DeploySymbioticNetworkAdapter` directly.
contract DeployCapNetworkAdapter is DeployEigenAdapter, DeploySymbioticNetworkAdapter { }
