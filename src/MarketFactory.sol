// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {MarketDeployer} from "./MarketDeployer.sol";
import {ReceiverTemplateUpgradeable} from "script/interfaces/ReceiverTemplateUpgradeable.sol";
import {MarketErrors} from "./libraries/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

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

    /// @notice Fixed amount of testnet USDC to mint into the factory (100,000 USDC with 6 decimals)
    /// @dev On mainnet this will be replaced with a real USDC funding flow instead of minting
    uint256 private Amount_Funding_Factory;

    /// @notice Tracks whether an address has been verified via World ID (Sybil-resistance)
    mapping(address => bool) public isVerified;

    /// @notice Records used World ID nullifier hashes to prevent the same human from verifying multiple wallets
    mapping(uint256 => bool) internal nullifierHashes;

    /// @notice Ordered list of all currently active (unresolved) market addresses
    /// @dev Markets are appended on creation and removed via swap-and-pop when resolved
    address[] public activeMarkets;

    /// @notice Maps a market address to its index in the activeMarkets array for O(1) removal
    mapping(address => uint256) public marketToIndex;

    /// @notice External deployer contract that holds the PredictionMarket creation bytecode
    /// @dev Separating deployment bytecode keeps MarketFactory under the 24 KB contract size limit
    MarketDeployer private marketDeployer;

    // ========================================
    // EVENTS
    // ========================================

    event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity);

    /// @notice Emitted when testnet USDC is minted into the factory via addLiquidityToFactory()
    event MarketFactory__LiquidityAdded(uint256 indexed amount);

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
     * @param _marketDeployer Address of deployer helper contract
     * @param _initialOwner Owner of the proxy
     */
    function initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)
        external
        initializer
    {
        if (
            _collateral == address(0) || _forwarder == address(0) || _marketDeployer == address(0)
                || _initialOwner == address(0)
        ) {
            revert MarketFactory__ZeroAddress();
        }

        __ReceiverTemplateUpgradeable_init(_forwarder, _initialOwner);
        collateral = IERC20(_collateral);
        marketDeployer = MarketDeployer(_marketDeployer);
        Amount_Funding_Factory = 100000e6;
    }

    /// @notice Updates the MarketDeployer helper contract address (owner only)
    /// @param _marketDeployer New deployer address; reverts on zero address
    /// @dev Use this if the deployer needs to be redeployed without redeploying the factory proxy
    function setMarketDeployer(address _marketDeployer) external onlyOwner {
        if (_marketDeployer == address(0)) revert MarketFactory__ZeroAddress();
        marketDeployer = MarketDeployer(_marketDeployer);
    }

    /// @notice UUPS upgrade authorization hook — only the owner can upgrade the implementation
    /// @param newImplementation Address of the new implementation contract; must not be zero
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert MarketFactory__ZeroAddress();
        }
    }

    /// @notice Mints testnet USDC into the factory so it has collateral to seed new markets
    /// @dev TESTNET ONLY — on mainnet, real USDC will be transferred in instead of minted.
    ///      The factory must be the owner of the collateral token for mint() to succeed.
    function addLiquidityToFactory() external onlyOwner {
        console.log(OutcomeToken(address(collateral)).owner(), "Owner");
        OutcomeToken(address(collateral)).mint(address(this), Amount_Funding_Factory);
        emit MarketFactory__LiquidityAdded(Amount_Funding_Factory);
    }

    /**
     * @notice Creates a new prediction market with initial liquidity
     */
    function createMarket(string calldata question, uint256 closeTime, uint256 resolutionTime, uint256 initialLiquidity)
        external
        onlyOwner
        returns (address market)
    {
        if (closeTime == 0 || resolutionTime == 0 || bytes(question).length == 0) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (closeTime > resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }

        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();
        if (address(marketDeployer) == address(0)) {
            revert MarketFactory__ZeroAddress();
        }

        PredictionMarket m = PredictionMarket(
            marketDeployer.deployPredictionMarket(
                question, address(collateral), closeTime, resolutionTime, address(this), _getForwarderAddress()
            )
        );

        // Fund the new market with collateral from the factory's balance
        collateral.safeTransfer(address(m), initialLiquidity);

        // Seed the AMM pool with equal YES/NO reserves backed by the transferred collateral
        m.seedLiquidity(initialLiquidity);

        // Transfer market ownership from the factory to the caller (deployer/admin)
        m.transferOwnership(msg.sender);

        marketCount++;

        // Register the market in the active list for Chainlink CRE to iterate over
        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;

        emit MarketCreated(marketCount, address(m), initialLiquidity);

        return address(m);
    }

    /// @notice Removes a resolved market from the activeMarkets array (swap-and-pop)
    /// @param market Address of the market that just resolved
    /// @dev Called by a PredictionMarket contract during its resolve() flow.
    ///      Uses swap-and-pop for O(1) removal: moves the last element into the removed slot.
    ///      TODO: restrict caller to only registered market contracts or the forwarder
    function removeResolvedMarket(address market) external {
        uint256 index = marketToIndex[market];
        address lastMarket = activeMarkets[activeMarkets.length - 1];

        // Overwrite the removed market with the last element, then pop
        activeMarkets[index] = lastMarket;
        marketToIndex[lastMarket] = index;
        activeMarkets.pop();

        delete marketToIndex[market];
    }

    /// @notice Chainlink CRE receiver hook — currently a no-op placeholder
    /// @dev Will contain factory-level settlement logic once Chainlink CRE integration is complete
    function _processReport(bytes calldata report) internal override {
        // Intentionally empty; satisfies the abstract ReceiverTemplateUpgradeable requirement
    }
}
