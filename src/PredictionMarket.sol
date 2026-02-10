// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OutcomeToken} from "./outcomeToken.sol";

contract PredictionMarket is Ownable, ReentrancyGuard {
    enum State {
        Open,
        Closed,
        Resolved
    }

    string public question;
    IERC20 public immutable collateral;

    OutcomeToken public yesToken;
    OutcomeToken public noToken;

    uint256 public immutable closeTime;
    uint256 public immutable resolutionTime;
    uint256 public immutable feeBps;

    uint256 public yesReserve;
    uint256 public noReserve;
    uint256 public accumulatedFees;

    State public state;
    bool public outcome; // true = YES

    event Trade(address indexed user, bool buyYes, uint256 amountIn, uint256 amountOut);

    event Resolved(bool outcome);
    event Redeemed(address indexed user, uint256 amount);

    constructor(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        uint256 _feeBps,
        uint256 _initialLiquidity,
        address owner_
    ) Ownable(msg.sender) {
        require(_closeTime < _resolutionTime, "Bad times");
        require(_feeBps <= 1_000, "Fee too high");

        question = _question;
        collateral = IERC20(_collateral);
        closeTime = _closeTime;
        resolutionTime = _resolutionTime;
        feeBps = _feeBps;

        yesReserve = _initialLiquidity;
        noReserve = _initialLiquidity;

        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        state = State.Open;
        _transferOwnership(owner_);
    }

    modifier beforeClose() {
        require(block.timestamp < closeTime, "Market closed");
        _;
    }

    /* ───────── BUY YES ───────── */
    function buyYes(uint256 amountIn, uint256 minYesOut) external nonReentrant beforeClose {
        uint256 fee = amountIn * feeBps / 10_000;
        uint256 net = amountIn - fee;

        uint256 k = yesReserve * noReserve;
        uint256 newYes = yesReserve + net;
        uint256 newNo = k / newYes;
        uint256 yesOut = noReserve - newNo;

        require(yesOut >= minYesOut, "Slippage exceeded");
        require(yesOut > 0, "Zero output");

        yesReserve = newYes;
        noReserve = newNo;
        accumulatedFees += fee;

        collateral.transferFrom(msg.sender, address(this), amountIn);
        yesToken.mint(msg.sender, yesOut);

        emit Trade(msg.sender, true, amountIn, yesOut);
    }

    /* ───────── SELL YES ───────── */

    function sellYes(uint256 yesIn, uint256 minUsdcOut) external nonReentrant beforeClose {
        uint256 k = yesReserve * noReserve;
        uint256 newYes = yesReserve - yesIn;
        uint256 newNo = k / newYes;
        uint256 grossOut = newNo - noReserve;

        uint256 fee = grossOut * feeBps / 10_000;
        uint256 netOut = grossOut - fee;

        require(netOut >= minUsdcOut, "Slippage exceeded");

        yesReserve = newYes;
        noReserve = newNo;
        accumulatedFees += fee;

        yesToken.burn(msg.sender, yesIn);
        collateral.transfer(msg.sender, netOut);

        emit Trade(msg.sender, false, yesIn, netOut);
    }
    
    /* ───────── RESOLUTION ───────── */

    function resolve(bool _outcome) external onlyOwner {
        require(block.timestamp >= resolutionTime, "Too early");
        require(state != State.Resolved, "Already resolved");

        outcome = _outcome;
        state = State.Resolved;

        emit Resolved(_outcome);
    }

    /* ───────── REDEEM ───────── */

    function redeem(uint256 amount) external nonReentrant {
        require(state == State.Resolved, "Not resolved");
        require(amount > 0, "Zero amount");

        if (outcome) {
            yesToken.burn(msg.sender, amount);
        } else {
            noToken.burn(msg.sender, amount);
        }

        collateral.transfer(msg.sender, amount);

        emit Redeemed(msg.sender, amount);
    }

    /* ───────── FEES ───────── */

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = accumulatedFees;
        accumulatedFees = 0;
        collateral.transfer(to, amount);
    }
}
