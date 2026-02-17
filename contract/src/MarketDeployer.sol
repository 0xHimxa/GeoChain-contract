// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @title MarketDeployer
 * @author 0xHimxa
 * @notice External helper contract that deploys PredictionMarket instances on behalf of the MarketFactory
 * @dev The PredictionMarket constructor bytecode is large. By moving deployment into this separate
 *      contract, the MarketFactory stays under the EVM's 24 KB contract size limit.
 *      Only the registered factory address is allowed to trigger deployments.
 */
contract MarketDeployer is Ownable {
    /// @notice The MarketFactory proxy address authorized to call deployPredictionMarket()
    address private factory;

    /// @notice Reverts when a non-factory address tries to deploy a market
    error MarketDeployer__OnlyFactory();
    /// @notice Reverts when a zero address is passed to setFactory()
    error MarketDeployer__ZeroAddress();
    /// @notice Reverts if setFactory() is called more than once (factory is immutable after first set)
    error MarketDeployer__FactoryAlreadySet();

    /// @notice Restricts function access to the registered factory address only
    modifier onlyFactory() {
        if (msg.sender != factory) revert MarketDeployer__OnlyFactory();
        _;
    }

    /// @param initialOwner Address that will own this deployer (typically the protocol admin)
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice One-time setter to bind this deployer to its MarketFactory proxy
    /// @param _factory Address of the MarketFactory proxy; cannot be zero and cannot be changed later
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert MarketDeployer__ZeroAddress();
        if (factory != address(0)) revert MarketDeployer__FactoryAlreadySet();
        factory = _factory;
    }

    /// @notice Returns the registered factory address
    function getFactory() external view returns (address) {
        return factory;
    }

    /// @notice Deploys a new PredictionMarket and transfers ownership to the factory
    /// @param question  The binary question the market will resolve
    /// @param collateral Address of the ERC20 collateral token (e.g., USDC)
    /// @param closeTime  Timestamp when trading closes
    /// @param resolutionTime Timestamp when the market can be resolved
    /// @param marketFactory  Address of the MarketFactory proxy (stored in the new market for callbacks)
    /// @param forwarder  Chainlink CRE forwarder address for receiving settlement reports
    /// @return market Address of the newly deployed PredictionMarket
    function deployPredictionMarket(
        string calldata question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address marketFactory,
        address forwarder
    ) external onlyFactory returns (address market) {
        PredictionMarket m = new PredictionMarket(
            question, collateral, closeTime, resolutionTime, marketFactory, forwarder
        );
        // Transfer ownership to the factory so it can seedLiquidity and then transfer to the admin
        m.transferOwnership(factory);
        return address(m);
    }
}
