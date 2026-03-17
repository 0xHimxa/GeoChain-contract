// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {PredictionMarketRouterVaultOperations} from "./PredictionMarketRouterVaultOperations.sol";
import {PredictionMarketRouterVaultBase} from "./PredictionMarketRouterVaultBase.sol";

/// @title PredictionMarketRouterVault
/// @notice Concrete router vault entry contract composed from base and operations modules.
/// @dev Deployed behind a proxy and initialized once via `initialize`.
contract PredictionMarketRouterVault is PredictionMarketRouterVaultOperations {
    /// @notice Initializes the router vault for proxy deployments.
    /// @param collateral Collateral token accepted by the router.
    /// @param forwarder Trusted forwarder for report handling.
    /// @param initialOwner Router owner.
    /// @param _marketFactory Linked market factory allowed to manage market mappings.
    function initialize(address collateral, address forwarder, address initialOwner, address _marketFactory)
        external
        initializer
    {
        __PredictionMarketRouterVaultBase_init(collateral, forwarder, initialOwner, _marketFactory);
    }
}
