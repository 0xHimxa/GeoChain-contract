// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @notice External deployer used to move PredictionMarket creation bytecode out of MarketFactory.
 */
contract MarketDeployer is Ownable {
    address private factory;

    error MarketDeployer__OnlyFactory();
    error MarketDeployer__ZeroAddress();
    error MarketDeployer__FactoryAlreadySet();

    modifier onlyFactory() {
        if (msg.sender != factory) revert MarketDeployer__OnlyFactory();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert MarketDeployer__ZeroAddress();
        if (factory != address(0)) revert MarketDeployer__FactoryAlreadySet();
        factory = _factory;
    }

    function getFactory() external view returns (address) {
        return factory;
    }

    function deployPredictionMarket(
        string calldata question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address marketFactory,
        address forwarder
    ) external onlyFactory returns (address market) {
        PredictionMarket m =
            new PredictionMarket(question, collateral, closeTime, resolutionTime, marketFactory, forwarder);
        m.transferOwnership(factory);
        return address(m);
    }
}
