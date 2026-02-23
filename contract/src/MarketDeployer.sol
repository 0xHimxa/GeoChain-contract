// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @title MarketDeployer
 * @author 0xHimxa
 * @notice External helper contract that deploys PredictionMarket instances on behalf of the MarketFactory
 * @dev The PredictionMarket constructor bytecode is large. By moving deployment into this separate
 *      contract, the MarketFactory stays under the EVM's 24 KB contract size limit.
 *      Only the registered factory address is allowed to trigger deployments.
 */
contract MarketDeployer {
    address public marketImplementation;

    error MarketDeployer__ZeroImplementation();

    constructor(address _marketImplementation) {
        if (_marketImplementation == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
    }


    function setImplementation(address _marketImplementation) external{
               if (_marketImplementation == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
    }


    /// @notice Deploys a new PredictionMarket for the calling factory
    /// @param question  The binary question the market will resolve
    /// @param collateral Address of the ERC20 collateral token (e.g., USDC)
    /// @param closeTime  Timestamp when trading closes
    /// @param resolutionTime Timestamp when the market can be resolved
    /// @param forwarder  Chainlink CRE forwarder address for receiving settlement reports
    /// @return market Address of the newly deployed PredictionMarket
    function deployPredictionMarket(
        string calldata question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address forwarder
    ) external returns (address market) {
        market = Clones.clone(marketImplementation);
        PredictionMarket(market).initialize(
            question, collateral, closeTime, resolutionTime, msg.sender, forwarder, msg.sender
        );
    }
}
