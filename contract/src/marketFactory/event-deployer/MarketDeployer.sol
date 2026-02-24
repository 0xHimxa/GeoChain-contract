// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PredictionMarket} from "../../predictionMarket/PredictionMarket.sol";

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
    address public owner;

event NewPrediction_ImplementationSet(address indexed market);
event MarketDeployer__NewOwnerSet(address indexed owner);



    error MarketDeployer__ZeroImplementation();
    error MarketDeployer__OnlyOwner();
   error MarketDeployer__NewOwnerCantbeAddressZero();


modifier onlyOnwer() {
    if (msg.sender != owner) revert MarketDeployer__OnlyOwner();
    _;
}


    constructor(address _marketImplementation,address _owner) {
        if (_marketImplementation == address(0) || _owner == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
        owner = _owner;

    }


    function setImplementation(address _marketImplementation) external onlyOnwer{
               if (_marketImplementation == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
        emit NewPrediction_ImplementationSet(marketImplementation);
    }


function setNewOwner(address _owner) external onlyOnwer{
               if (_owner == address(0)) revert MarketDeployer__NewOwnerCantbeAddressZero();
        owner = _owner;
        emit MarketDeployer__NewOwnerSet(_owner);

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
    ) external onlyOnwer returns (address market) {
        market = Clones.clone(marketImplementation);
        PredictionMarket(market).initialize(
            question, collateral, closeTime, resolutionTime, msg.sender, forwarder, msg.sender
        );
    }
}
