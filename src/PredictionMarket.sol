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
    uint256 public immutable feeBps;
    uint256 private constant SWAP_FEE_BPS = 400;
    uint256 private constant MINT_COMPLETE_SETS_FEE_BPS = 300;
    uint256 private constant REDEEM_COMPLETE_SETS_FEE_BPS = 200;
    uint256 private constant FEE_PRESECION_BPS = 10_000;

    uint256 public yesReserve;
    uint256 public noReserve;
    bool public seeded;
    uint256 public totalShares;
    mapping(address => uint256) public lpShares;
    uint256 public collateralReserve;

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

    constructor(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        uint256 _feeBps,
        address owner_
    ) Ownable(msg.sender) {
        require(_closeTime < _resolutionTime, "Bad times");
        require(_feeBps <= 1_000, "Fee too high");

        s_question = _question;
        i_collateral = IERC20(_collateral);
        closeTime = _closeTime;
        resolutionTime = _resolutionTime;
        feeBps = _feeBps;

        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        state = State.Open;
        _transferOwnership(owner_);
    }

    modifier marketOpen() {
        _updateState();
        require(state == State.Open, "Market closed");
        require(!paused(), "Paused");
        _;
    }

    modifier seededOnly() {
        require(seeded, "Not seeded");
        _;
    }

    modifier notResolved() {
        require(state != State.Resolved, "Resolved");
        _;
    }

    function _updateState() internal {
        if (state == State.Open && block.timestamp >= closeTime) {
            state = State.Closed;
        }
    }

    /* ───────── LIQUIDITY ───────── */
    function seedLiquidity(uint256 amount) external onlyOwner whenNotPaused {
        require(!seeded, "Already seeded");
        require(amount > 0, "Zero amount");
        require(state == State.Open, "Market closed");

        require(i_collateral.balanceOf(address(this)) >= amount, "Insufficient collateral");
        yesToken.mint(address(this), amount);
        noToken.mint(address(this), amount);

        yesReserve = amount;
        noReserve = amount;
        seeded = true;
        totalShares = amount;
        lpShares[msg.sender] = amount;
        collateralReserve = amount;

        emit LiquiditySeeded(amount);
    }

    /* ───────── LP SHARES ───────── */
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 collateralAmount, uint256 minShares)
        external
        nonReentrant
        marketOpen
        seededOnly
    {
        require(yesAmount > 0 && noAmount > 0, "Zero amount");
        require(collateralAmount > 0, "Zero collateral");
        require(yesAmount == noAmount, "YES/NO mismatch");
        require(yesAmount == collateralAmount, "Collateral mismatch");

        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), yesAmount);
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), noAmount);
        i_collateral.safeTransferFrom(msg.sender, address(this), collateralAmount);

        uint256 yesShare = (yesAmount * totalShares) / yesReserve;
        uint256 noShare = (noAmount * totalShares) / noReserve;
        uint256 shares = yesShare < noShare ? yesShare : noShare;

        require(shares >= minShares, "Slippage exceeded");
        require(shares > 0, "Zero shares");
        require(collateralAmount >= shares, "Insufficient collateral");

        uint256 usedYes = (shares * yesReserve) / totalShares;
        uint256 usedNo = (shares * noReserve) / totalShares;

        yesReserve += usedYes;
        noReserve += usedNo;

        totalShares += shares;
        lpShares[msg.sender] += shares;
        collateralReserve += shares;

        if (yesAmount > usedYes) {
            IERC20(address(yesToken)).safeTransfer(msg.sender, yesAmount - usedYes);
        }
        if (noAmount > usedNo) {
            IERC20(address(noToken)).safeTransfer(msg.sender, noAmount - usedNo);
        }
        if (collateralAmount > shares) {
            i_collateral.safeTransfer(msg.sender, collateralAmount - shares);
        }

        emit LiquidityAdded(msg.sender, usedYes, usedNo, shares);
    }

    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut)
        external
        nonReentrant
        notResolved
        seededOnly
        whenNotPaused
    {
        require(shares > 0, "Zero shares");
        require(lpShares[msg.sender] >= shares, "Insufficient shares");

        uint256 yesOut = (yesReserve * shares) / totalShares;
        uint256 noOut = (noReserve * shares) / totalShares;
        uint256 collateralOut = (collateralReserve * shares) / totalShares;

        require(yesOut >= minYesOut && noOut >= minNoOut, "Slippage exceeded");

        lpShares[msg.sender] -= shares;
        totalShares -= shares;

        yesReserve -= yesOut;
        noReserve -= noOut;
        collateralReserve -= collateralOut;

        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);
        i_collateral.safeTransfer(msg.sender, collateralOut);

        emit LiquidityRemoved(msg.sender, yesOut, noOut, shares);
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
        collateralReserve += fee;

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
        collateralReserve += fee;

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
