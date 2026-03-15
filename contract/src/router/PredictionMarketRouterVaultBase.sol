// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    ReceiverTemplateUpgradeable
} from "../../script/interfaces/ReceiverTemplateUpgradeable.sol";
import {MarketConstants} from "../libraries/MarketTypes.sol";

/// @title IPredictionMarketLike
/// @notice Minimal market interface consumed by the router vault.
/// @dev LMSR trades are CRE-report-driven, so swap/LP functions are removed.
interface IPredictionMarketLike {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function resolution() external view returns (uint8);
    function liquidityParam() external view returns (uint256);

    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function redeem(uint256 amount) external;
    function disputeProposedResolution(uint8 proposedOutcome) external;

    function executeBuy(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) external;

    function executeSell(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) external;
}

/// @title PredictionMarketRouterVaultBase
/// @notice Shared storage, events, and guard utilities for router vault modules.
/// @dev Holds user-credit accounting and report action hashes used by operation modules.
abstract contract PredictionMarketRouterVaultBase is
    Initializable,
    ReceiverTemplateUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    error Router__ZeroAddress();
    error Router__MarketNotAllowed();
    error Router__CollateralMismatch();
    error Router__InsufficientBalance();
    error Router__InsufficientUntrackedCollateral();
    error Router__InvalidDelta();
    error Router__InvalidAmount();
    error Router__InvalidDepositId();
    error Router__EthDepositAlreadyProcessed();
    error Router__ActionNotRecognized();
    error Router__RiskExposureExceeded();
    error Router__MarketNotInitialized();
    error Router__MarketNotResolved();
    error Router__AgentNotAuthorized();
    error Router__AgentPermissionExpired();
    error Router__AgentActionNotAllowed();
    error Router__AgentAmountExceeded();
    error Router__EthTransferFailed();
    error PredictionMarketRouterVault__NotAuthorizedMarketMapper();

    bytes32 internal constant HASHED_DEPOSIT_FOR =
        keccak256(abi.encode("routerDepositFor"));
    bytes32 internal constant HASHED_WITHDRAW_COLLATERAL =
        keccak256(abi.encode("routerWithdrawCollateralFor"));
    bytes32 internal constant HASHED_WITHDRAW_OUTCOME =
        keccak256(abi.encode("routerWithdrawOutcomeFor"));
    bytes32 internal constant HASHED_MINT =
        keccak256(abi.encode("routerMintCompleteSets"));
    bytes32 internal constant HASHED_REDEEM =
        keccak256(abi.encode("routerRedeemCompleteSets"));
    bytes32 internal constant HASHED_BUY =
        keccak256(abi.encode("routerBuy"));
    bytes32 internal constant HASHED_SELL =
        keccak256(abi.encode("routerSell"));
    bytes32 internal constant HASHED_CREDIT_FROM_FIAT =
        keccak256(abi.encode("routerCreditFromFiat"));
    bytes32 internal constant HASHED_CREDIT_FROM_ETH =
        keccak256(abi.encode("routerCreditFromEth"));
    bytes32 internal constant HASHED_REDEEM_WINNINGS =
        keccak256(abi.encode("routerRedeem"));
    bytes32 internal constant HASHED_DISPUTE =
        keccak256(abi.encode("routerDisputeProposedResolution"));

    //Agents
    bytes32 internal constant HASHED_AGENT_MINT =
        keccak256(abi.encode("routerAgentMintCompleteSets"));
    bytes32 internal constant HASHED_AGENT_REDEEM =
        keccak256(abi.encode("routerAgentRedeemCompleteSets"));
    bytes32 internal constant HASHED_AGENT_REDEEM_WINNINGS =
        keccak256(abi.encode("routerAgentRedeem"));
    bytes32 internal constant HASHED_AGENT_DISPUTE =
        keccak256(abi.encode("routerAgentDisputeProposedResolution"));
    bytes32 internal constant HASHED_AGENT_BUY =
        keccak256(abi.encode("routerAgentBuy"));
    bytes32 internal constant HASHED_AGENT_SELL =
        keccak256(abi.encode("routerAgentSell"));
    bytes32 internal constant HASHED_AGENT_REVOKE_PERMISSION =
        keccak256(abi.encode("routerAgentRevokePermission"));

    uint32 internal constant AGENT_ACTION_MINT = 1 << 0;
    uint32 internal constant AGENT_ACTION_REDEEM_COMPLETE_SETS = 1 << 1;
    uint32 internal constant AGENT_ACTION_REDEEM_WINNINGS = 1 << 2;
    uint32 internal constant AGENT_ACTION_DISPUTE = 1 << 3;
    uint32 internal constant AGENT_ACTION_BUY = 1 << 4;
    uint32 internal constant AGENT_ACTION_SELL = 1 << 5;

    struct AgentPermission {
        bool enabled;
        uint64 expiresAt;
        uint128 maxAmountPerAction;
        uint32 actionMask;
    }

    IERC20 public collateralToken;
    uint256 public totalCollateralCredits;
    address public marketFactory;

    mapping(address => bool) public allowedMarkets;

    mapping(address => uint256) public collateralCredits;
    mapping(address => mapping(address => uint256)) public tokenCredits;
    mapping(address => mapping(address => uint256)) public lpShareCredits;
    mapping(address => uint256) public userRiskExposure;
    mapping(address => bool) public isRiskExempt;
    //agent Permision
    mapping(address => mapping(address => AgentPermission))
        public agentPermissions;
    mapping(bytes32 => bool) public processedEthDeposits;

    event MarketAllowlistUpdated(address indexed market, bool allowed);
    event Deposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event OutcomeWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event CompleteSetsMinted(
        address indexed user,
        address indexed market,
        uint256 collateralIn,
        uint256 yesOut,
        uint256 noOut
    );
    event CompleteSetsRedeemed(
        address indexed user,
        address indexed market,
        uint256 amount,
        uint256 collateralOut
    );
    event WinningsRedeemed(
        address indexed user,
        address indexed market,
        uint256 amount,
        uint256 collateralOut
    );
    event BoughtSideCompleted(
        address indexed user,
        address indexed market,
        uint256 yesIn,
        uint256 noOut
    );
    event SideSoldCompleted(
        address indexed user,
        address indexed market,
        uint256 noIn,
        uint256 yesOut
    );

    event CollateralCreditedFromFiat(address indexed user, uint256 amount);
    event EthReceived(address indexed sender, uint256 amountWei);
    event EthWithdrawn(address indexed recipient, uint256 amountWei);
    event CollateralCreditedFromEth(
        address indexed user,
        uint256 amount,
        bytes32 indexed depositId
    );
    event RouterRiskExemptUpdated(address indexed account, bool exempt);
    event DisputeSubmitted(
        address indexed user,
        address indexed market,
        uint8 proposedOutcome
    );
    event AgentPermissionUpdated(
        address indexed user,
        address indexed agent,
        bool enabled,
        uint32 actionMask,
        uint128 maxAmountPerAction,
        uint64 expiresAt
    );
    event AgentPermissionRevoked(address indexed user, address indexed agent);
    event AgentActionExecuted(
        address indexed user,
        address indexed agent,
        string actionType,
        uint256 boundedAmount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes base router dependencies and owner/forwarder wiring for proxy deployments.
    function __PredictionMarketRouterVaultBase_init(
        address collateral,
        address forwarder,
        address initialOwner,
        address _marketFactory
    ) internal onlyInitializing {
        if (collateral == address(0)) revert Router__ZeroAddress();
        if (_marketFactory == address(0)) revert Router__ZeroAddress();
        __ReceiverTemplateUpgradeable_init(forwarder, initialOwner);
        collateralToken = IERC20(collateral);
        marketFactory = _marketFactory;
    }

    /// @dev UUPS authorization hook.
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        if (newImplementation == address(0)) revert Router__ZeroAddress();
    }

    /// @notice Emits a deposit event for native ETH transfers to support off-chain crediting flows.
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    /// @notice Returns collateral balance held by router but not assigned to user credits.
    /// @dev Useful for reconciliation and credit-from-offchain workflows.
    function getUntrackedCollateral() external view returns (uint256) {
        uint256 balance = collateralToken.balanceOf(address(this));
        if (balance <= totalCollateralCredits) return 0;
        return balance - totalCollateralCredits;
    }

    /// @notice Alias helper for untracked collateral value.
    function getRouterUntrackedValue()
        external
        view
        returns (uint256 untracked)
    {
        uint256 balance = collateralToken.balanceOf(address(this));
        uint256 credited = totalCollateralCredits;
        untracked = balance > credited ? balance - credited : 0;
    }

    /// @dev Reverts if a market is not explicitly allowlisted.
    function _validateMarket(address market) internal view {
        if (!allowedMarkets[market]) revert Router__MarketNotAllowed();
    }

    /// @dev Reverts if market collateral token differs from router collateral.
    function _ensureCollateralMatch(address market) internal view {
        if (
            IPredictionMarketLike(market).i_collateral() !=
            address(collateralToken)
        ) {
            revert Router__CollateralMismatch();
        }
    }

    /// @dev Ensures spender has enough allowance by bumping toward max when needed.
    function _ensureAllowance(
        IERC20 token,
        address spender,
        uint256 amountNeeded
    ) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance >= amountNeeded) return;
        uint256 increase = type(uint256).max - allowance;
        token.safeIncreaseAllowance(spender, increase);
    }

    uint256[50] private __gap;
}
