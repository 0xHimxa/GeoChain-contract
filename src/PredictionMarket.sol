// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {OutcomeToken} from "./outcomeToken.sol";

contract PredictionMarket is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum State {
        Open,
        Closed,
        Resolved
    }

    string public s_question;
    string public s_Proof_Url;
    IERC20 public immutable i_collateral;

    OutcomeToken public immutable yesToken;
    OutcomeToken public immutable noToken;

    uint256 public immutable closeTime;
    uint256 public immutable resolutionTime;
    uint256 private constant SWAP_FEE_BPS = 400;
    uint256 private constant MINT_COMPLETE_SETS_FEE_BPS = 300;
    uint256 private constant REDEEM_COMPLETE_SETS_FEE_BPS = 200;
    uint256 private constant FEE_PRESECION_BPS = 10_000;
    uint256 private constant MINIMU_ADDLIQUIDITYSHARE = 50;
    uint256 public yesReserve;
    uint256 public noReserve;
    bool public seeded;
    uint256 public totalShares;
    mapping(address => uint256) public lpShares;

    State public state;

    enum Resolution {
        Unset,
        Yes,
        No,
        Invalid
    }

    Resolution public resolution;

    event Trade(address indexed user, bool yesForNo, uint256 amountIn, uint256 amountOut);
    event Resolved(Resolution outcome);

    event Redeemed(address indexed user, uint256 amount);
    event CompleteSetsMinted(address indexed user, uint256 amount);
    event CompleteSetsRedeemed(address indexed user, uint256 amount);
    event LiquiditySeeded(uint256 amount);
    event LiquidityAdded(address indexed user, uint256 yesAmount, uint256 noAmount, uint256 shares);
    event LiquidityRemoved(address indexed user, uint256 yesAmount, uint256 noAmount, uint256 shares);
    event SharesTransferred(address indexed from, address indexed to, uint256 shares);

    error PredictionMarket__CloseTimeGreaterThanResolutionTime();
    error PredictionMarket__InvalidArguments_PassedInConstructor();
    error PredictionMarket__Isclosed();
    error PredictionMarket__IsPaused();
    error PredictionMarket__InitailConstantLiquidityNotSetYet();
    error PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();
    error PredictionMarket__InitailConstantLiquidityAlreadySet();
    error PredictionMarket__FundingInitailAountGreaterThanAmountSent();
    error PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
    error PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();
    error PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
    error PredictionMarket__AddLiquidity_InsuffientTokenBalance();
    error PredictionMarket__WithDrawLiquidity_SlippageExceeded();
    error PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
    error PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();

    constructor(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        address owner_
    ) Ownable(msg.sender) {
        if (_collateral == address(0) || _closeTime == 0 || _resolutionTime == 0 || bytes(_question).length == 0) revert PredictionMarket__InvalidArguments_PassedInConstructor();

        if (_closeTime > _resolutionTime) revert PredictionMarket__CloseTimeGreaterThanResolutionTime();

        s_question = _question;

        i_collateral = IERC20(_collateral);
        closeTime = _closeTime;
        resolutionTime = _resolutionTime;

        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        state = State.Open;
        _transferOwnership(owner_);
    }

    modifier marketOpen() {
        _updateState();
        require(state == State.Open, "Market closed");
        if (state == State.Closed) revert PredictionMarket__Isclosed();
        if (paused()) revert PredictionMarket__IsPaused();
        _;
    }

    modifier seededOnly() {
        if (!seeded) revert PredictionMarket__InitailConstantLiquidityNotSetYet();
        _;
    }

    function _updateState() internal {
        if (state == State.Open && block.timestamp >= closeTime) {
            state = State.Closed;
        }
    }

    /* ───────── LIQUIDITY ───────── */
    function seedLiquidity(uint256 amount) external onlyOwner whenNotPaused {
        if (seeded) revert PredictionMarket__InitailConstantLiquidityAlreadySet();
        if (amount == 0) revert PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();

        uint256 contractBalance = i_collateral.balanceOf(address(this));

        if (contractBalance < amount) revert PredictionMarket__FundingInitailAountGreaterThanAmountSent();

        yesReserve = amount;
        noReserve = amount;
        seeded = true;
        totalShares = amount;
        lpShares[msg.sender] = amount;

        yesToken.mint(address(this), amount);
        noToken.mint(address(this), amount);

        emit LiquiditySeeded(amount);
    }

    /* ───────── LP SHARES ───────── */
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares)
        external
        nonReentrant
        marketOpen
        seededOnly
    {
        if (yesAmount == 0 && noAmount == 0) revert PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
        if (yesAmount < MINIMU_ADDLIQUIDITYSHARE || noAmount < MINIMU_ADDLIQUIDITYSHARE) {
            revert PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
        }

        uint256 yesTokenBalance = yesToken.balanceOf(address(msg.sender));
        uint256 noTokenBalance = noToken.balanceOf(address(msg.sender));
        if (yesTokenBalance < yesAmount || noTokenBalance < noAmount) {
            revert PredictionMarket__AddLiquidity_InsuffientTokenBalance();
        }

        uint256 yesShare = (yesAmount * totalShares) / yesReserve;
        uint256 noShare = (noAmount * totalShares) / noReserve;
        uint256 shares = yesShare < noShare ? yesShare : noShare;

        require(shares >= minShares, "Slippage exceeded");
        if (shares < minShares) revert PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();

        uint256 usedYes = (shares * yesReserve) / totalShares;
        uint256 usedNo = (shares * noReserve) / totalShares;

        yesReserve += usedYes;
        noReserve += usedNo;

        totalShares += shares;
        lpShares[msg.sender] += shares;

        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), usedYes);
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), usedNo);

        emit LiquidityAdded(msg.sender, usedYes, usedNo, shares);
    }

    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut)
        external
        nonReentrant
        seededOnly
        whenNotPaused
    {
        uint256 userShares = lpShares[msg.sender];
        require(shares > 0, "Zero shares");
        if (shares == 0) revert PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        if (userShares < shares) revert PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();

        // Calculate outputs based on the total reserves BEFORE updating
        uint256 yesOut = (yesReserve * shares) / totalShares;
        uint256 noOut = (noReserve * shares) / totalShares;

        require(yesOut >= minYesOut && noOut >= minNoOut, "Slippage exceeded");
        if (yesOut < minYesOut || noOut < minNoOut) revert PredictionMarket__WithDrawLiquidity_SlippageExceeded();

        // Update LP info
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;

        // Update reserves AFTER calculating output
        yesReserve -= yesOut;
        noReserve -= noOut;

        // Transfer tokens
        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);

        emit LiquidityRemoved(msg.sender, yesOut, noOut, shares);
    }

    function removeLiquidityAndRedeemCollateral(uint256 shares, uint256 minCollateralOut)
        external
        nonReentrant
        seededOnly
        whenNotPaused
    {
        uint256 userShares = lpShares[msg.sender];
        if (shares == 0) revert PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        if (userShares < shares) revert PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();

     
        uint256 yesOut = (yesReserve * shares) / totalShares;
        uint256 noOut = (noReserve * shares) / totalShares;

        // 2 Update LP balances and pool reserves
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;
        yesReserve -= yesOut;
        noReserve -= noOut;

        emit LiquidityRemoved(msg.sender, yesOut, noOut, shares);

        // 3 Burn YES/NO tokens and apply redeem fee
        uint256 feeYes = (yesOut * REDEEM_COMPLETE_SETS_FEE_BPS) / FEE_PRESECION_BPS;
        uint256 feeNo = (noOut * REDEEM_COMPLETE_SETS_FEE_BPS) / FEE_PRESECION_BPS;

        uint256 netYes = yesOut - feeYes;
        uint256 netNo = noOut - feeNo;

        // The collateral user receives is the sum of net YES + net NO
        uint256 totalCollateralOut = netYes + netNo;
        require(totalCollateralOut >= minCollateralOut, "Slippage exceeded");

        // Burn the YES/NO tokens (from the contract balance)
        yesToken.burn(address(this), yesOut);
        noToken.burn(address(this), noOut);

        // Transfer collateral to user
        i_collateral.safeTransfer(msg.sender, totalCollateralOut);

        emit CompleteSetsRedeemed(msg.sender, totalCollateralOut);
    }

    function transferShares(address to, uint256 shares) external whenNotPaused {
        require(to != address(0), "Bad recipient");
        require(lpShares[msg.sender] >= shares, "Insufficient shares");

        lpShares[msg.sender] -= shares;
        lpShares[to] += shares;

        emit SharesTransferred(msg.sender, to, shares);
    }

    /* ───────── COMPLETE SETS ───────── */
    function mintCompleteSets(uint256 amount) external nonReentrant marketOpen {
        require(amount > 0, "Zero amount");

        i_collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 fee = (amount * MINT_COMPLETE_SETS_FEE_BPS) / FEE_PRESECION_BPS;
        uint256 netAmount = amount - fee;
        require(netAmount > 0, "Zero output");

        yesToken.mint(msg.sender, netAmount);
        noToken.mint(msg.sender, netAmount);

        emit CompleteSetsMinted(msg.sender, netAmount);
    }

    function redeemCompleteSets(uint256 amount) external nonReentrant whenNotPaused {
        require(state != State.Resolved, "Resolved");
        require(amount > 0, "Zero amount");

        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
        uint256 fee = (amount * REDEEM_COMPLETE_SETS_FEE_BPS) / FEE_PRESECION_BPS;
        uint256 netAmount = amount - fee;
        require(netAmount > 0, "Zero output");

        i_collateral.safeTransfer(msg.sender, netAmount);

        emit CompleteSetsRedeemed(msg.sender, netAmount);
    }

    /* ───────── SWAPS (YES <-> NO) ───────── */
    function swapYesForNo(uint256 yesIn, uint256 minNoOut) external nonReentrant marketOpen seededOnly {
        require(yesIn > 0, "Zero input");

        uint256 noOut = _swapYesForNoFromPool(yesIn, minNoOut, msg.sender);
        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), yesIn);

        emit Trade(msg.sender, true, yesIn, noOut);
    }

    function swapNoForYes(uint256 noIn, uint256 minYesOut) external nonReentrant marketOpen seededOnly {
        require(noIn > 0, "Zero input");

        uint256 yesOut = _swapNoForYesFromPool(noIn, minYesOut, msg.sender);
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), noIn);

        emit Trade(msg.sender, false, noIn, yesOut);
    }

    function _swapYesForNoFromPool(uint256 yesIn, uint256 minNoOut, address recipient)
        internal
        returns (uint256 netOut)
    {
        uint256 k = yesReserve * noReserve;
        uint256 newYes = yesReserve + yesIn;
        uint256 newNo = k / newYes;
        uint256 grossOut = noReserve - newNo;
        uint256 fee = (grossOut * SWAP_FEE_BPS) / FEE_PRESECION_BPS;
        netOut = grossOut - fee;

        require(netOut >= minNoOut, "Slippage exceeded");
        require(netOut > 0, "Zero output");

        yesReserve = newYes;
        noReserve = newNo + fee;

        IERC20(address(noToken)).safeTransfer(recipient, netOut);
    }

    function _swapNoForYesFromPool(uint256 noIn, uint256 minYesOut, address recipient)
        internal
        returns (uint256 netOut)
    {
        uint256 k = yesReserve * noReserve;
        uint256 newNo = noReserve + noIn;
        uint256 newYes = k / newNo;
        uint256 grossOut = yesReserve - newYes;
        uint256 fee = (grossOut * SWAP_FEE_BPS) / FEE_PRESECION_BPS;
        netOut = grossOut - fee;

        require(netOut >= minYesOut, "Slippage exceeded");
        require(netOut > 0, "Zero output");

        noReserve = newNo;
        yesReserve = newYes + fee;

        IERC20(address(yesToken)).safeTransfer(recipient, netOut);
    }

    /* ───────── RESOLUTION ───────── */
    // will fix this
    function resolve(bool _outcome) external onlyOwner {
        _updateState();
        require(block.timestamp >= resolutionTime, "Too early");
        require(state != State.Resolved, "Already resolved");
        require(state == State.Closed, "Market still open");

        // outcome = _outcome;
        state = State.Resolved;

        // emit Resolved(_outcome);
    }

    /* ───────── REDEEM ───────── */

    function redeem(uint256 amount) external nonReentrant whenNotPaused {
        require(state == State.Resolved, "Not resolved");
        require(amount > 0, "Zero amount");

        if (resolution == Resolution.Yes) {
            yesToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, amount);
        } else if (resolution == Resolution.No) {
            noToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, amount);
        } else if (resolution == Resolution.Invalid) {
            revert("Use redeemInvalid");
        } else {
            revert("Invalid resolution");
        }

        emit Redeemed(msg.sender, amount);
    }

    // function redeemInvalid(bool redeemYes, uint256 amount) external nonReentrant whenNotPaused {
    //     require(state == State.Resolved, "Not resolved");
    //     require(resolution == Resolution.Invalid, "Not invalid");
    //     require(amount > 0, "Zero amount");

    //     if (redeemYes) {
    //         yesToken.burn(msg.sender, amount);
    //     } else {
    //         noToken.burn(msg.sender, amount);
    //     }

    //     i_collateral.safeTransfer(msg.sender, amount / 2);

    //     emit Redeemed(msg.sender, amount / 2);
    // }

    /* ───────── PREVIEW ───────── */
    function getYesForNoQuote(uint256 yesIn) external view returns (uint256 netOut, uint256 fee) {
        require(yesIn > 0, "Zero input");
        uint256 k = yesReserve * noReserve;
        uint256 newYes = yesReserve + yesIn;
        uint256 newNo = k / newYes;
        uint256 grossOut = noReserve - newNo;
        fee = (grossOut * SWAP_FEE_BPS) / FEE_PRESECION_BPS;
        netOut = grossOut - fee;
    }

    function getNoForYesQuote(uint256 noIn) external view returns (uint256 netOut, uint256 fee) {
        require(noIn > 0, "Zero input");
        uint256 k = yesReserve * noReserve;
        uint256 newNo = noReserve + noIn;
        uint256 newYes = k / newNo;
        uint256 grossOut = yesReserve - newYes;
        fee = (grossOut * SWAP_FEE_BPS) / FEE_PRESECION_BPS;
        netOut = grossOut - fee;
    }

    /* ───────── PAUSE CONTROL ───────── */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
