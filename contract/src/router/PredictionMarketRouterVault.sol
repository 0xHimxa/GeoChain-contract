// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
contract PredictionMarketRouterVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Router__ZeroAddress();
    error Router__MarketNotAllowed();
    error Router__CollateralMismatch();
    error Router__InsufficientBalance();
    error Router__InvalidDelta();

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

    constructor(address collateral, address initialOwner) Ownable(initialOwner) {
        if (collateral == address(0) || initialOwner == address(0)) revert Router__ZeroAddress();
        collateralToken = IERC20(collateral);
    }

    function setMarketAllowed(address market, bool allowed) external onlyOwner {
        if (market == address(0)) revert Router__ZeroAddress();
        allowedMarkets[market] = allowed;
        emit MarketAllowlistUpdated(market, allowed);
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralCredits[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        uint256 bal = collateralCredits[msg.sender];
        if (bal < amount) revert Router__InsufficientBalance();
        collateralCredits[msg.sender] = bal - amount;
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function withdrawOutcomeToken(address token, uint256 amount) external nonReentrant {
        uint256 bal = tokenCredits[msg.sender][token];
        if (bal < amount) revert Router__InsufficientBalance();
        tokenCredits[msg.sender][token] = bal - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit OutcomeWithdrawn(msg.sender, token, amount);
    }

    function mintCompleteSets(address market, uint256 amount) external nonReentrant {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        uint256 userCollateral = collateralCredits[msg.sender];
        if (userCollateral < amount) revert Router__InsufficientBalance();
        collateralCredits[msg.sender] = userCollateral - amount;

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

        tokenCredits[msg.sender][yes] += yesDelta;
        tokenCredits[msg.sender][no] += noDelta;

        emit CompleteSetsMinted(msg.sender, market, amount, yesDelta, noDelta);
    }

    function redeemCompleteSets(address market, uint256 amount) external nonReentrant {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[msg.sender][yes];
        uint256 noBal = tokenCredits[msg.sender][no];
        if (yesBal < amount || noBal < amount) revert Router__InsufficientBalance();
        tokenCredits[msg.sender][yes] = yesBal - amount;
        tokenCredits[msg.sender][no] = noBal - amount;

        uint256 collateralBefore = collateralToken.balanceOf(address(this));
        _ensureAllowance(IERC20(yes), market, amount);
        _ensureAllowance(IERC20(no), market, amount);
        IPredictionMarketLike(market).redeemCompleteSets(amount);
        uint256 collateralAfter = collateralToken.balanceOf(address(this));

        if (collateralAfter < collateralBefore) revert Router__InvalidDelta();
        uint256 collateralDelta = collateralAfter - collateralBefore;
        collateralCredits[msg.sender] += collateralDelta;

        emit CompleteSetsRedeemed(msg.sender, market, amount, collateralDelta);
    }

    function swapYesForNo(address market, uint256 yesIn, uint256 minNoOut) external nonReentrant {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[msg.sender][yes];
        if (yesBal < yesIn) revert Router__InsufficientBalance();
        tokenCredits[msg.sender][yes] = yesBal - yesIn;

        uint256 noBefore = IERC20(no).balanceOf(address(this));
        _ensureAllowance(IERC20(yes), market, yesIn);
        IPredictionMarketLike(market).swapYesForNo(yesIn, minNoOut);
        uint256 noAfter = IERC20(no).balanceOf(address(this));

        if (noAfter < noBefore) revert Router__InvalidDelta();
        uint256 noOut = noAfter - noBefore;
        tokenCredits[msg.sender][no] += noOut;

        emit SwappedYesForNo(msg.sender, market, yesIn, noOut);
    }

    function swapNoForYes(address market, uint256 noIn, uint256 minYesOut) external nonReentrant {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 noBal = tokenCredits[msg.sender][no];
        if (noBal < noIn) revert Router__InsufficientBalance();
        tokenCredits[msg.sender][no] = noBal - noIn;

        uint256 yesBefore = IERC20(yes).balanceOf(address(this));
        _ensureAllowance(IERC20(no), market, noIn);
        IPredictionMarketLike(market).swapNoForYes(noIn, minYesOut);
        uint256 yesAfter = IERC20(yes).balanceOf(address(this));

        if (yesAfter < yesBefore) revert Router__InvalidDelta();
        uint256 yesOut = yesAfter - yesBefore;
        tokenCredits[msg.sender][yes] += yesOut;

        emit SwappedNoForYes(msg.sender, market, noIn, yesOut);
    }

    function addLiquidity(address market, uint256 yesAmount, uint256 noAmount, uint256 minShares) external nonReentrant {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[msg.sender][yes];
        uint256 noBal = tokenCredits[msg.sender][no];
        if (yesBal < yesAmount || noBal < noAmount) revert Router__InsufficientBalance();
        tokenCredits[msg.sender][yes] = yesBal - yesAmount;
        tokenCredits[msg.sender][no] = noBal - noAmount;

        uint256 sharesBefore = IPredictionMarketLike(market).lpShares(address(this));
        _ensureAllowance(IERC20(yes), market, yesAmount);
        _ensureAllowance(IERC20(no), market, noAmount);
        IPredictionMarketLike(market).addLiquidity(yesAmount, noAmount, minShares);
        uint256 sharesAfter = IPredictionMarketLike(market).lpShares(address(this));
        if (sharesAfter < sharesBefore) revert Router__InvalidDelta();

        uint256 sharesOut = sharesAfter - sharesBefore;
        lpShareCredits[msg.sender][market] += sharesOut;

        emit LiquidityAdded(msg.sender, market, yesAmount, noAmount, sharesOut);
    }

    function removeLiquidity(address market, uint256 shares, uint256 minYesOut, uint256 minNoOut) external nonReentrant {
        _validateMarket(market);
        uint256 userShares = lpShareCredits[msg.sender][market];
        if (userShares < shares) revert Router__InsufficientBalance();
        lpShareCredits[msg.sender][market] = userShares - shares;

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
        tokenCredits[msg.sender][yes] += yesOut;
        tokenCredits[msg.sender][no] += noOut;

        emit LiquidityRemoved(msg.sender, market, shares, yesOut, noOut);
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

