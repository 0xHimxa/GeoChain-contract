// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReceiverTemplate} from "../../script/interfaces/ReceiverTemplate.sol";

interface IPredictionMarketLike {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function lpShares(address account) external view returns (uint256);

    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function swapYesForNo(uint256 yesIn, uint256 minNoOut) external;
    function swapNoForYes(uint256 noIn, uint256 minYesOut) external;
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares) external;
    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut) external;
}

/// @title PredictionMarketRouterVault
/// @notice Router vault that enables one-time collateral approval UX while handling market interactions on behalf of users.
/// @dev Users deposit collateral once to this vault and then trade through internal balances.
/// Market contracts see this vault as trader/liquidity provider, which avoids repeated per-market approvals.
contract PredictionMarketRouterVault is ReceiverTemplate, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Router__ZeroAddress();
    error Router__MarketNotAllowed();
    error Router__CollateralMismatch();
    error Router__InsufficientBalance();
    error Router__InvalidDelta();
    error Router__ActionNotRecognized();

    bytes32 private constant HASHED_DEPOSIT_FOR = keccak256(abi.encode("routerDepositFor"));
    bytes32 private constant HASHED_WITHDRAW_COLLATERAL = keccak256(abi.encode("routerWithdrawCollateralFor"));
    bytes32 private constant HASHED_WITHDRAW_OUTCOME = keccak256(abi.encode("routerWithdrawOutcomeFor"));
    bytes32 private constant HASHED_MINT = keccak256(abi.encode("routerMintCompleteSets"));
    bytes32 private constant HASHED_REDEEM = keccak256(abi.encode("routerRedeemCompleteSets"));
    bytes32 private constant HASHED_SWAP_YES_FOR_NO = keccak256(abi.encode("routerSwapYesForNo"));
    bytes32 private constant HASHED_SWAP_NO_FOR_YES = keccak256(abi.encode("routerSwapNoForYes"));
    bytes32 private constant HASHED_ADD_LIQ = keccak256(abi.encode("routerAddLiquidity"));
    bytes32 private constant HASHED_REMOVE_LIQ = keccak256(abi.encode("routerRemoveLiquidity"));

    IERC20 public immutable collateralToken;

    // Market allowlist to avoid interacting with arbitrary contracts.
    mapping(address => bool) public allowedMarkets;

    // Internal user balances managed by the vault.
    mapping(address => uint256) public collateralCredits;
    mapping(address => mapping(address => uint256)) public tokenCredits; // user => token => amount
    mapping(address => mapping(address => uint256)) public lpShareCredits; // user => market => shares

    event MarketAllowlistUpdated(address indexed market, bool allowed);
    event Deposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event OutcomeWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CompleteSetsMinted(address indexed user, address indexed market, uint256 collateralIn, uint256 yesOut, uint256 noOut);
    event CompleteSetsRedeemed(address indexed user, address indexed market, uint256 amount, uint256 collateralOut);
    event SwappedYesForNo(address indexed user, address indexed market, uint256 yesIn, uint256 noOut);
    event SwappedNoForYes(address indexed user, address indexed market, uint256 noIn, uint256 yesOut);
    event LiquidityAdded(address indexed user, address indexed market, uint256 yesIn, uint256 noIn, uint256 sharesOut);
    event LiquidityRemoved(address indexed user, address indexed market, uint256 sharesIn, uint256 yesOut, uint256 noOut);

    constructor(address collateral, address forwarder, address initialOwner) ReceiverTemplate(forwarder, initialOwner) {
        if (collateral == address(0)) revert Router__ZeroAddress();
        collateralToken = IERC20(collateral);
    }

    function setMarketAllowed(address market, bool allowed) external onlyOwner {
        if (market == address(0)) revert Router__ZeroAddress();
        allowedMarkets[market] = allowed;
        emit MarketAllowlistUpdated(market, allowed);
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        _depositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        _withdrawCollateral(msg.sender, amount);
    }

    function withdrawOutcomeToken(address token, uint256 amount) external nonReentrant {
        _withdrawOutcomeToken(msg.sender, token, amount);
    }

    function mintCompleteSets(address market, uint256 amount) external nonReentrant {
        _mintCompleteSets(msg.sender, market, amount);
    }

    function redeemCompleteSets(address market, uint256 amount) external nonReentrant {
        _redeemCompleteSets(msg.sender, market, amount);
    }

    function swapYesForNo(address market, uint256 yesIn, uint256 minNoOut) external nonReentrant {
        _swapYesForNo(msg.sender, market, yesIn, minNoOut);
    }

    function swapNoForYes(address market, uint256 noIn, uint256 minYesOut) external nonReentrant {
        _swapNoForYes(msg.sender, market, noIn, minYesOut);
    }

    function addLiquidity(address market, uint256 yesAmount, uint256 noAmount, uint256 minShares) external nonReentrant {
        _addLiquidity(msg.sender, market, yesAmount, noAmount, minShares);
    }

    function removeLiquidity(address market, uint256 shares, uint256 minYesOut, uint256 minNoOut) external nonReentrant {
        _removeLiquidity(msg.sender, market, shares, minYesOut, minNoOut);
    }

    function _depositCollateral(address user, uint256 amount) internal {
        collateralToken.safeTransferFrom(user, address(this), amount);
        collateralCredits[user] += amount;
        emit Deposited(user, amount);
    }

    function _withdrawCollateral(address user, uint256 amount) internal {
        uint256 bal = collateralCredits[user];
        if (bal < amount) revert Router__InsufficientBalance();
        collateralCredits[user] = bal - amount;
        collateralToken.safeTransfer(user, amount);
        emit CollateralWithdrawn(user, amount);
    }

    function _withdrawOutcomeToken(address user, address token, uint256 amount) internal {
        uint256 bal = tokenCredits[user][token];
        if (bal < amount) revert Router__InsufficientBalance();
        tokenCredits[user][token] = bal - amount;
        IERC20(token).safeTransfer(user, amount);
        emit OutcomeWithdrawn(user, token, amount);
    }

    function _mintCompleteSets(address user, address market, uint256 amount) internal {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        uint256 userCollateral = collateralCredits[user];
        if (userCollateral < amount) revert Router__InsufficientBalance();
        collateralCredits[user] = userCollateral - amount;

        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();
        uint256 yesBefore = IERC20(yes).balanceOf(address(this));
        uint256 noBefore = IERC20(no).balanceOf(address(this));

        _ensureAllowance(collateralToken, market, amount);
        IPredictionMarketLike(market).mintCompleteSets(amount);

        uint256 yesAfter = IERC20(yes).balanceOf(address(this));
        uint256 noAfter = IERC20(no).balanceOf(address(this));
        uint256 yesDelta = yesAfter - yesBefore;
        uint256 noDelta = noAfter - noBefore;

        tokenCredits[user][yes] += yesDelta;
        tokenCredits[user][no] += noDelta;

        emit CompleteSetsMinted(user, market, amount, yesDelta, noDelta);
    }

    function _redeemCompleteSets(address user, address market, uint256 amount) internal {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[user][yes];
        uint256 noBal = tokenCredits[user][no];
        if (yesBal < amount || noBal < amount) revert Router__InsufficientBalance();
        tokenCredits[user][yes] = yesBal - amount;
        tokenCredits[user][no] = noBal - amount;

        uint256 collateralBefore = collateralToken.balanceOf(address(this));
        _ensureAllowance(IERC20(yes), market, amount);
        _ensureAllowance(IERC20(no), market, amount);
        IPredictionMarketLike(market).redeemCompleteSets(amount);
        uint256 collateralAfter = collateralToken.balanceOf(address(this));

        if (collateralAfter < collateralBefore) revert Router__InvalidDelta();
        uint256 collateralDelta = collateralAfter - collateralBefore;
        collateralCredits[user] += collateralDelta;

        emit CompleteSetsRedeemed(user, market, amount, collateralDelta);
    }

    function _swapYesForNo(address user, address market, uint256 yesIn, uint256 minNoOut) internal {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[user][yes];
        if (yesBal < yesIn) revert Router__InsufficientBalance();
        tokenCredits[user][yes] = yesBal - yesIn;

        uint256 noBefore = IERC20(no).balanceOf(address(this));
        _ensureAllowance(IERC20(yes), market, yesIn);
        IPredictionMarketLike(market).swapYesForNo(yesIn, minNoOut);
        uint256 noAfter = IERC20(no).balanceOf(address(this));

        if (noAfter < noBefore) revert Router__InvalidDelta();
        uint256 noOut = noAfter - noBefore;
        tokenCredits[user][no] += noOut;

        emit SwappedYesForNo(user, market, yesIn, noOut);
    }

    function _swapNoForYes(address user, address market, uint256 noIn, uint256 minYesOut) internal {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 noBal = tokenCredits[user][no];
        if (noBal < noIn) revert Router__InsufficientBalance();
        tokenCredits[user][no] = noBal - noIn;

        uint256 yesBefore = IERC20(yes).balanceOf(address(this));
        _ensureAllowance(IERC20(no), market, noIn);
        IPredictionMarketLike(market).swapNoForYes(noIn, minYesOut);
        uint256 yesAfter = IERC20(yes).balanceOf(address(this));

        if (yesAfter < yesBefore) revert Router__InvalidDelta();
        uint256 yesOut = yesAfter - yesBefore;
        tokenCredits[user][yes] += yesOut;

        emit SwappedNoForYes(user, market, noIn, yesOut);
    }

    function _addLiquidity(address user, address market, uint256 yesAmount, uint256 noAmount, uint256 minShares)
        internal
    {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[user][yes];
        uint256 noBal = tokenCredits[user][no];
        if (yesBal < yesAmount || noBal < noAmount) revert Router__InsufficientBalance();
        tokenCredits[user][yes] = yesBal - yesAmount;
        tokenCredits[user][no] = noBal - noAmount;

        uint256 sharesBefore = IPredictionMarketLike(market).lpShares(address(this));
        _ensureAllowance(IERC20(yes), market, yesAmount);
        _ensureAllowance(IERC20(no), market, noAmount);
        IPredictionMarketLike(market).addLiquidity(yesAmount, noAmount, minShares);
        uint256 sharesAfter = IPredictionMarketLike(market).lpShares(address(this));
        if (sharesAfter < sharesBefore) revert Router__InvalidDelta();

        uint256 sharesOut = sharesAfter - sharesBefore;
        lpShareCredits[user][market] += sharesOut;

        emit LiquidityAdded(user, market, yesAmount, noAmount, sharesOut);
    }

    function _removeLiquidity(address user, address market, uint256 shares, uint256 minYesOut, uint256 minNoOut)
        internal
    {
        _validateMarket(market);
        uint256 userShares = lpShareCredits[user][market];
        if (userShares < shares) revert Router__InsufficientBalance();
        lpShareCredits[user][market] = userShares - shares;

        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();
        uint256 yesBefore = IERC20(yes).balanceOf(address(this));
        uint256 noBefore = IERC20(no).balanceOf(address(this));

        IPredictionMarketLike(market).removeLiquidity(shares, minYesOut, minNoOut);

        uint256 yesAfter = IERC20(yes).balanceOf(address(this));
        uint256 noAfter = IERC20(no).balanceOf(address(this));
        if (yesAfter < yesBefore || noAfter < noBefore) revert Router__InvalidDelta();

        uint256 yesOut = yesAfter - yesBefore;
        uint256 noOut = noAfter - noBefore;
        tokenCredits[user][yes] += yesOut;
        tokenCredits[user][no] += noOut;

        emit LiquidityRemoved(user, market, shares, yesOut, noOut);
    }

    function _processReport(bytes calldata report) internal override nonReentrant {
        (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));

        if (actionTypeHash == HASHED_DEPOSIT_FOR) {
            (address user, uint256 amount) = abi.decode(payload, (address, uint256));
            _depositCollateral(user, amount);
        } else if (actionTypeHash == HASHED_WITHDRAW_COLLATERAL) {
            (address user, uint256 amount) = abi.decode(payload, (address, uint256));
            _withdrawCollateral(user, amount);
        } else if (actionTypeHash == HASHED_WITHDRAW_OUTCOME) {
            (address user, address token, uint256 amount) = abi.decode(payload, (address, address, uint256));
            _withdrawOutcomeToken(user, token, amount);
        } else if (actionTypeHash == HASHED_MINT) {
            (address user, address market, uint256 amount) = abi.decode(payload, (address, address, uint256));
            _mintCompleteSets(user, market, amount);
        } else if (actionTypeHash == HASHED_REDEEM) {
            (address user, address market, uint256 amount) = abi.decode(payload, (address, address, uint256));
            _redeemCompleteSets(user, market, amount);
        } else if (actionTypeHash == HASHED_SWAP_YES_FOR_NO) {
            (address user, address market, uint256 yesIn, uint256 minNoOut) =
                abi.decode(payload, (address, address, uint256, uint256));
            _swapYesForNo(user, market, yesIn, minNoOut);
        } else if (actionTypeHash == HASHED_SWAP_NO_FOR_YES) {
            (address user, address market, uint256 noIn, uint256 minYesOut) =
                abi.decode(payload, (address, address, uint256, uint256));
            _swapNoForYes(user, market, noIn, minYesOut);
        } else if (actionTypeHash == HASHED_ADD_LIQ) {
            (address user, address market, uint256 yesAmount, uint256 noAmount, uint256 minShares) =
                abi.decode(payload, (address, address, uint256, uint256, uint256));
            _addLiquidity(user, market, yesAmount, noAmount, minShares);
        } else if (actionTypeHash == HASHED_REMOVE_LIQ) {
            (address user, address market, uint256 shares, uint256 minYesOut, uint256 minNoOut) =
                abi.decode(payload, (address, address, uint256, uint256, uint256));
            _removeLiquidity(user, market, shares, minYesOut, minNoOut);
        } else {
            revert Router__ActionNotRecognized();
        }
    }

    function _validateMarket(address market) internal view {
        if (!allowedMarkets[market]) revert Router__MarketNotAllowed();
    }

    function _ensureCollateralMatch(address market) internal view {
        if (IPredictionMarketLike(market).i_collateral() != address(collateralToken)) {
            revert Router__CollateralMismatch();
        }
    }

    function _ensureAllowance(IERC20 token, address spender, uint256 amountNeeded) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance >= amountNeeded) return;
        uint256 increase = type(uint256).max - allowance;
        token.safeIncreaseAllowance(spender, increase);
    }
}
