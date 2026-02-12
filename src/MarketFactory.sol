// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @title MarketFactory
 * @author 0xHimxa
 * @notice Factory contract for deploying new prediction markets with initial liquidity
 * @dev Uses the factory pattern to create and track prediction market instances
 *      All markets use the same collateral token (e.g., USDC)
 *      Only the owner can create new markets to ensure quality control
 */
contract MarketFactory is Ownable {
    using SafeERC20 for IERC20;

    // ========================================
    // STATE VARIABLES
    // ========================================

    /// @notice The ERC20 token used as collateral for all markets (e.g., USDC)
    IERC20 public immutable collateral;

    /// @notice Total number of markets created by this factory
    uint256 public marketCount;

    /// @notice Mapping from market ID to market contract address
    mapping(uint256 => address) public markets;

    // ========================================
    // EVENTS
    // ========================================

    /**
     * @notice Emitted when a new prediction market is created
     * @param marketId Unique identifier for the market
     * @param market Address of the deployed market contract
     * @param question Prediction question for the market
     * @param closeTime Timestamp when market closes for trading
     * @param resolutionTime Timestamp when market can be resolved
     * @param initialLiquidity Amount of collateral used to seed the market
     */
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

    /// @notice Thrown when initial liquidity is zero
    error MarketFactory__ZeroLiquidity();

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the factory with a collateral token
     * @param _collateral Address of the ERC20 token to use as collateral for all markets
     * @dev The collateral token is immutable and applies to all markets created by this factory
     */
    constructor(address _collateral) Ownable(msg.sender) {
        collateral = IERC20(_collateral);
    }

    // ========================================
    // EXTERNAL FUNCTIONS
    // ========================================

    /**
     * @notice Creates a new prediction market with initial liquidity
     * @param question The prediction question (e.g., "Will ETH be above $5000 on Dec 31, 2024?")
     * @param closeTime Timestamp when market closes for trading
     * @param resolutionTime Timestamp when market can be resolved (must be after closeTime)
     * @param initialLiquidity Amount of collateral to seed the market with
     * @return market Address of the newly deployed market contract
     * @dev Only callable by owner to ensure market quality
     *      Caller must approve this factory to spend initialLiquidity amount of collateral
     *      The factory seeds the market, mints LP shares, and transfers ownership to caller
     */
    function createMarket(string calldata question, uint256 closeTime, uint256 resolutionTime, uint256 initialLiquidity)
        external
        onlyOwner
        nonReentrant
        returns (address market)
    {
        // Validate initial liquidity
        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();

        // Deploy new prediction market contract
        // Market is initially owned by this factory for setup
        PredictionMarket m =
            new PredictionMarket(question, address(collateral), closeTime, resolutionTime, address(this));

        // Transfer collateral from caller to the new market
        collateral.safeTransferFrom(msg.sender, address(m), initialLiquidity);

        // Seed the market with initial liquidity
        // This creates equal YES and NO reserves and mints LP shares
        m.seedLiquidity(initialLiquidity);

        // Transfer LP shares to the market creator
        // Creator now owns all initial liquidity provider shares
        m.transferShares(msg.sender, initialLiquidity);

        // Transfer market ownership to creator
        // Creator can now resolve the market and manage admin functions
        m.transferOwnership(msg.sender);

        // Register the market in factory tracking
        marketCount++;
        markets[marketCount] = address(m);

        emit MarketCreated(marketCount, address(m), question, closeTime, resolutionTime, initialLiquidity);

        return address(m);
    }
}
