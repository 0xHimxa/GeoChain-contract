// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PredictionMarket} from "./PredictionMarket.sol";
import {ReceiverTemplateUpgradeable} from "script/interfaces/ReceiverTemplateUpgradeable.sol";

/**
 * @title MarketFactory
 * @author 0xHimxa
 * @notice Factory contract for deploying new prediction markets with initial liquidity
 * @dev UUPS upgradeable factory. Uses initialize() instead of constructor.
 */
contract MarketFactory is Initializable, ReceiverTemplateUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ========================================
    // STATE VARIABLES
    // ========================================

    /// @notice The ERC20 token used as collateral for all markets (e.g., USDC)
    IERC20 public collateral;

    /// @notice Total number of markets created by this factory
    uint256 public marketCount;

    /// @notice Mapping from market ID to market contract address
    mapping(uint256 => address) public markets;

    // Storage for verified status
    mapping(address => bool) public isVerified;

    // Prevent the same "Human" from verifying multiple wallets
    mapping(uint256 => bool) internal nullifierHashes;

    // Active market tracking
    address[] public activeMarkets;
    mapping(address => uint256) public marketToIndex;

    // ========================================
    // EVENTS
    // ========================================

    event MarketCreated(
        uint256 indexed marketId,
        address market,
        string question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 initialLiquidity
    );

    // ========================================
    // ERRORS
    // ========================================

    error MarketFactory__ZeroLiquidity();
    error MarketFactory__ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory for proxy usage.
     * @param _collateral Address of collateral token
     * @param _forwarder Address passed to each newly created market
     * @param _initialOwner Owner of the proxy
     */
    function initialize(address _collateral, address _forwarder, address _initialOwner) external initializer {
        if (_collateral == address(0) || _forwarder == address(0) || _initialOwner == address(0)) {
            revert MarketFactory__ZeroAddress();
        }

        __ReceiverTemplateUpgradeable_init(_forwarder, _initialOwner);
        collateral = IERC20(_collateral);
    }



     function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert MarketFactory__ZeroAddress();
    }

    

    /**
     * @notice Creates a new prediction market with initial liquidity
     */
    function createMarket(string calldata question, uint256 closeTime, uint256 resolutionTime, uint256 initialLiquidity)
        external
        onlyOwner
        returns (address market)
    {
        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();

        PredictionMarket m =
            new PredictionMarket(
                question, address(collateral), closeTime, resolutionTime, address(this), _getForwarderAddress()
            );

        collateral.safeTransferFrom(msg.sender, address(m), initialLiquidity);

        m.seedLiquidity(initialLiquidity);
        m.transferShares(msg.sender, initialLiquidity);
        m.transferOwnership(msg.sender);

        marketCount++;
        markets[marketCount] = address(m);
        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;

        emit MarketCreated(marketCount, address(m), question, closeTime, resolutionTime, initialLiquidity);

        return address(m);
    }

    // Called when a prediction market resolves to remove it from active list
    //onlyforward should be able to call this
    function removeResolvedMarket(address market) external {
        uint256 index = marketToIndex[market];
        address lastMarket = activeMarkets[activeMarkets.length - 1];

        activeMarkets[index] = lastMarket;
        marketToIndex[lastMarket] = index;
        activeMarkets.pop();

        if (marketCount > 0) {
            marketCount = marketCount - 1;
        }

        delete marketToIndex[market];
    }

   

    function _processReport(bytes calldata report) internal override {
        report;
    }
}
