// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PredictionMarket} from "../../predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../token/OutcomeToken.sol";

/// @title MarketDeployer
/// @notice Deploys market clones for the factory and initializes each instance.
/// @dev Keeps heavy deployment bytecode out of the upgradeable factory contract.
contract MarketDeployer {
    /// @notice Current implementation address used by `Clones.clone`.
    address public marketImplementation;
    /// @notice Admin address allowed to manage deployer configuration.
    address public owner;

    event NewPrediction_ImplementationSet(address indexed market);
    event MarketDeployer__NewOwnerSet(address indexed owner);

    error MarketDeployer__ZeroImplementation();
    error MarketDeployer__OnlyOwner();
    error MarketDeployer__NewOwnerCantbeAddressZero();

    /// @dev Restricts management and deployment calls to deployer owner.
    modifier onlyOnwer() {
        if (msg.sender != owner) revert MarketDeployer__OnlyOwner();
        _;
    }

    /// @param _marketImplementation Initial prediction market implementation for cloning.
    /// @param _owner Admin that can update implementation and owner.
    constructor(address _marketImplementation, address _owner) {
        if (_marketImplementation == address(0) || _owner == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
        owner = _owner;
    }

    /// @notice Updates implementation template for all future clones.
    /// @dev Existing deployed markets are unaffected because clones are immutable instances.
    function setImplementation(address _marketImplementation) external onlyOnwer {
        if (_marketImplementation == address(0)) revert MarketDeployer__ZeroImplementation();
        marketImplementation = _marketImplementation;
        emit NewPrediction_ImplementationSet(marketImplementation);
    }

    /// @notice Transfers deployer admin role to a new address.
    /// @dev Required when factory ownership or deployment authority changes.
    function setNewOwner(address _owner) external onlyOnwer {
        if (_owner == address(0)) revert MarketDeployer__NewOwnerCantbeAddressZero();
        owner = _owner;
        emit MarketDeployer__NewOwnerSet(_owner);
    }

    /// @notice Clones and initializes a new prediction market instance.
    /// @param question Market question.
    /// @param collateral Collateral token used by market.
    /// @param closeTime Trading close timestamp.
    /// @param resolutionTime Earliest resolution timestamp.
    /// @param forwarder Forwarder accepted for report delivery.
    /// @return market Address of deployed clone.
    /// @dev Initialization passes `msg.sender` as both market-factory reference and initial owner;
    /// the caller is expected to be the authorized factory contract.
    function deployPredictionMarket(
        string calldata question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address forwarder
    ) external onlyOnwer returns (address market) {
        market = Clones.clone(marketImplementation);

        PredictionMarket(market).initialize(
            question, collateral, closeTime, resolutionTime, msg.sender, forwarder, address(this)
        );

        OutcomeToken yesToken = new OutcomeToken("YES", "YES", market);
        OutcomeToken noToken = new OutcomeToken("NO", "NO", market);
        PredictionMarket(market).setOutcomeTokens(address(yesToken), address(noToken));
        PredictionMarket(market).transferOwnership(msg.sender);
    }
}
