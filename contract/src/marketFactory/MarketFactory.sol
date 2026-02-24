// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarketFactoryOperations} from "./MarketFactoryOperations.sol";

/// @title MarketFactory
/// @notice Upgradeable entry contract exposing factory initialization.
/// @custom:oz-upgrades-from MarketFactory
contract MarketFactory is MarketFactoryOperations {
    /// @notice Proxy initializer entrypoint.
    /// @dev Keeps initializer signature at top-level concrete contract for upgrade tooling,
    /// while all initialization logic remains in inherited modules.
    function initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)
        public
        override
    {
        super.initialize(_collateral, _forwarder, _marketDeployer, _initialOwner);
    }
}
