// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {PredictionMarketRouterVaultOperations} from "./PredictionMarketRouterVaultOperations.sol";
import {PredictionMarketRouterVaultBase} from "./PredictionMarketRouterVaultBase.sol";

/// @title PredictionMarketRouterVault
/// @notice Concrete router vault entry contract composed from base and operations modules.
/// @dev Keeps constructor surface stable for scripts/tests while logic lives in inherited modules.
contract PredictionMarketRouterVault is PredictionMarketRouterVaultOperations {
    /// @notice Deploys the router vault and initializes immutable dependencies.
    /// @param collateral Collateral token accepted by the router.
    /// @param forwarder Trusted forwarder for report handling.
    /// @param initialOwner Router owner.
    /// @param _marketFactory Linked market factory allowed to manage market mappings.
    constructor(address collateral, address forwarder, address initialOwner, address _marketFactory)
        PredictionMarketRouterVaultBase(collateral, forwarder, initialOwner, _marketFactory)
    {}
}
