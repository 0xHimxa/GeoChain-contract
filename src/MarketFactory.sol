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

// amount to  fund the factory with 100,000 USDC
    uint256 private Amount_Funding_Factory;


    // Storage for verified status
    mapping(address => bool) public isVerified;

    // Prevent the same "Human" from verifying multiple wallets
    mapping(uint256 => bool) internal nullifierHashes;

    // Active market tracking
    address[] public activeMarkets;
    mapping(address => uint256) public marketToIndex;
    MarketDeployer private marketDeployer;

    // ========================================
    // EVENTS
    // ========================================

    event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        uint256 indexed initialLiquidity
    );


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
        if (_collateral == address(0) || _forwarder == address(0) || _marketDeployer == address(0) || _initialOwner == address(0)) {
            revert MarketFactory__ZeroAddress();
        }

        __ReceiverTemplateUpgradeable_init(_forwarder, _initialOwner);
        collateral = IERC20(_collateral);
        marketDeployer = MarketDeployer(_marketDeployer);
      Amount_Funding_Factory = 100000e6;
    }
 
    function setMarketDeployer(address _marketDeployer) external onlyOwner {
        if (_marketDeployer == address(0)) revert MarketFactory__ZeroAddress();
        marketDeployer = MarketDeployer(_marketDeployer);
    }



     function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert MarketFactory__ZeroAddress();
    }


//in testnet the funding logic need to be change instead of minting to funding it with USDC on mainnet
 // for know i will just be minting my own USDC
    function addLiquidityToFactory() external onlyOwner{
        console.log(OutcomeToken(address(collateral)).owner(),"Owner");
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
  if ( closeTime == 0 || resolutionTime == 0 || bytes(question).length == 0) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (closeTime > resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }

        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();
        if (address(marketDeployer) == address(0)) revert MarketFactory__ZeroAddress();

        PredictionMarket m = PredictionMarket(
            marketDeployer.deployPredictionMarket(
                question, address(collateral), closeTime, resolutionTime, address(this), _getForwarderAddress()
            )
        );

        collateral.safeTransfer(address(m), initialLiquidity);

        m.seedLiquidity(initialLiquidity);
    
      m.transferOwnership(msg.sender);

        marketCount++;
      
        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;

        emit MarketCreated(marketCount, address(m) , initialLiquidity);


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


        delete marketToIndex[market];
    }

   

    function _processReport(bytes calldata report) internal override {
        report;
    }



}
