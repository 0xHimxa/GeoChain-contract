// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReceiverTemplate} from "../../script/interfaces/ReceiverTemplate.sol";
import {MarketConstants} from "../libraries/MarketTypes.sol";

/// @title IPredictionMarketLike
/// @notice Minimal market interface consumed by the router vault.
interface IPredictionMarketLike {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function resolution() external view returns (uint8);
    function lpShares(address account) external view returns (uint256);

    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function redeem(uint256 amount) external;
    function swapYesForNo(uint256 yesIn, uint256 minNoOut) external;
    function swapNoForYes(uint256 noIn, uint256 minYesOut) external;
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares) external;
    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut) external;
}

/// @title PredictionMarketRouterVaultBase
/// @notice Shared storage, events, and guard utilities for router vault modules.
/// @dev Holds user-credit accounting and report action hashes used by operation modules.
abstract contract PredictionMarketRouterVaultBase is ReceiverTemplate, ReentrancyGuard {
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
    error Router__MarketNotResolved();
    error PredictionMarketRouterVault__NotAuthorizedMarketMapper();

    bytes32 internal constant HASHED_DEPOSIT_FOR = keccak256(abi.encode("routerDepositFor"));
    bytes32 internal constant HASHED_WITHDRAW_COLLATERAL = keccak256(abi.encode("routerWithdrawCollateralFor"));
    bytes32 internal constant HASHED_WITHDRAW_OUTCOME = keccak256(abi.encode("routerWithdrawOutcomeFor"));
    bytes32 internal constant HASHED_MINT = keccak256(abi.encode("routerMintCompleteSets"));
    bytes32 internal constant HASHED_REDEEM = keccak256(abi.encode("routerRedeemCompleteSets"));
    bytes32 internal constant HASHED_SWAP_YES_FOR_NO = keccak256(abi.encode("routerSwapYesForNo"));
    bytes32 internal constant HASHED_SWAP_NO_FOR_YES = keccak256(abi.encode("routerSwapNoForYes"));
    bytes32 internal constant HASHED_ADD_LIQ = keccak256(abi.encode("routerAddLiquidity"));
    bytes32 internal constant HASHED_REMOVE_LIQ = keccak256(abi.encode("routerRemoveLiquidity"));
    bytes32 internal constant HASHED_CREDIT_FROM_FIAT = keccak256(abi.encode("routerCreditFromFiat"));
    bytes32 internal constant HASHED_CREDIT_FROM_ETH = keccak256(abi.encode("routerCreditFromEth"));
    bytes32 internal constant HASHED_REDEEM_WINNINGS = keccak256(abi.encode("routerRedeem"));

    IERC20 public immutable collateralToken;
    uint256 public totalCollateralCredits;
    address public immutable marketFactory;

    mapping(address => bool) public allowedMarkets;

    mapping(address => uint256) public collateralCredits;
    mapping(address => mapping(address => uint256)) public tokenCredits;
    mapping(address => mapping(address => uint256)) public lpShareCredits;
    mapping(address => uint256) public userRiskExposure;
    mapping(address => bool) public isRiskExempt;
    mapping(bytes32 => bool) public processedEthDeposits;

    event MarketAllowlistUpdated(address indexed market, bool allowed);
    event Deposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event OutcomeWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CompleteSetsMinted(address indexed user, address indexed market, uint256 collateralIn, uint256 yesOut, uint256 noOut);
    event CompleteSetsRedeemed(address indexed user, address indexed market, uint256 amount, uint256 collateralOut);
    event WinningsRedeemed(address indexed user, address indexed market, uint256 amount, uint256 collateralOut);
    event SwappedYesForNo(address indexed user, address indexed market, uint256 yesIn, uint256 noOut);
    event SwappedNoForYes(address indexed user, address indexed market, uint256 noIn, uint256 yesOut);
    event LiquidityAdded(address indexed user, address indexed market, uint256 yesIn, uint256 noIn, uint256 sharesOut);
    event LiquidityRemoved(address indexed user, address indexed market, uint256 sharesIn, uint256 yesOut, uint256 noOut);
    event CollateralCreditedFromFiat(address indexed user, uint256 amount);
    event EthReceived(address indexed sender, uint256 amountWei);
    event CollateralCreditedFromEth(address indexed user, uint256 amount, bytes32 indexed depositId);
    event RouterRiskExemptUpdated(address indexed account, bool exempt);

    /// @notice Creates a router vault bound to one collateral token and market factory.
    /// @param collateral Collateral token accepted by all markets reachable via this router.
    /// @param forwarder Trusted forwarder used by `ReceiverTemplate`.
    /// @param initialOwner Initial router owner.
    /// @param _marketFactory Factory authorized to manage market allowlisting.
    constructor(address collateral, address forwarder, address initialOwner, address _marketFactory)
        ReceiverTemplate(forwarder, initialOwner)
    {
        if (collateral == address(0)) revert Router__ZeroAddress();
        collateralToken = IERC20(collateral);
        marketFactory = _marketFactory;
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
    function getRouterUntrackedValue() external view returns (uint256 untracked) {
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
        if (IPredictionMarketLike(market).i_collateral() != address(collateralToken)) {
            revert Router__CollateralMismatch();
        }
    }

    /// @dev Ensures spender has enough allowance by bumping toward max when needed.
    function _ensureAllowance(IERC20 token, address spender, uint256 amountNeeded) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance >= amountNeeded) return;
        uint256 increase = type(uint256).max - allowance;
        token.safeIncreaseAllowance(spender, increase);
    }
}
