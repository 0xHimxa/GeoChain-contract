// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @notice External deployer used to move PredictionMarket creation bytecode out of MarketFactory.
 */
contract MarketDeployer {
    function deployPredictionMarket(
        string calldata question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address marketFactory,
        address forwarder
    ) external returns (address market) {
        PredictionMarket m =
            new PredictionMarket(question, collateral, closeTime, resolutionTime, marketFactory, forwarder);
        return address(m);
    }
}
