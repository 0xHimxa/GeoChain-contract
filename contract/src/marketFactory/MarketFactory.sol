// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarketFactoryOperations} from "./MarketFactoryOperations.sol";

/// @title MarketFactory
/// @custom:oz-upgrades-from MarketFactory
contract MarketFactory is MarketFactoryOperations {
    function initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)
        public
        override
    {
        super.initialize(_collateral, _forwarder, _marketDeployer, _initialOwner);
    }
}
