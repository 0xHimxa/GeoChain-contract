// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketConstants, MarketEvents, MarketErrors, State, Resolution} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {PredictionMarketBase} from "./PredictionMarketBase.sol";

abstract contract PredictionMarketLiquidity is PredictionMarketBase {
    using SafeERC20 for IERC20;

    function seedLiquidity(uint256 amount) external onlyOwner whenNotPaused {
        if (seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityAlreadySet();
        }
        if (amount == 0) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();
        }

        uint256 contractBalance = i_collateral.balanceOf(address(this));
        if (contractBalance < amount) {
            revert MarketErrors.PredictionMarket__FundingInitailAountGreaterThanAmountSent();
        }

        yesReserve = amount;
        noReserve = amount;
        seeded = true;

        totalShares = amount;
        lpShares[msg.sender] = amount;

        yesToken.mint(address(this), amount);
        noToken.mint(address(this), amount);

        emit MarketEvents.LiquiditySeeded(amount);
    }

    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares)
        public
        virtual
        nonReentrant
        marketOpen
        seededOnly
    {
        if (yesAmount == 0 && noAmount == 0) {
            revert MarketErrors.PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
        }
        if (
            yesAmount < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE
                || noAmount < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE
        ) {
            revert MarketErrors.PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
        }

        uint256 yesTokenBalance = yesToken.balanceOf(address(msg.sender));
        uint256 noTokenBalance = noToken.balanceOf(address(msg.sender));
        if (yesTokenBalance < yesAmount || noTokenBalance < noAmount) {
            revert MarketErrors.PredictionMarket__AddLiquidity_InsuffientTokenBalance();
        }

        (uint256 shares, uint256 usedYes, uint256 usedNo) =
            AMMLib.calculateShares(yesAmount, noAmount, totalShares, yesReserve, noReserve);

        if (shares < minShares) {
            revert MarketErrors.PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();
        }

        yesReserve += usedYes;
        noReserve += usedNo;

        totalShares += shares;
        lpShares[msg.sender] += shares;

        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), usedYes);
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), usedNo);

        emit MarketEvents.LiquidityAdded(msg.sender, usedYes, usedNo, shares);
    }

    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut)
        public
        virtual
        nonReentrant
        seededOnly
        marketOpen
    {
        uint256 userShares = lpShares[msg.sender];

        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        uint256 yesOut = AMMLib.calculateProportionalOutput(yesReserve, shares, totalShares);
        uint256 noOut = AMMLib.calculateProportionalOutput(noReserve, shares, totalShares);

        if (yesOut < minYesOut || noOut < minNoOut) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded();
        }

        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;

        yesReserve -= yesOut;
        noReserve -= noOut;

        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);

        emit MarketEvents.LiquidityRemoved(msg.sender, yesOut, noOut, shares);
    }

    function removeLiquidityAndRedeemCollateral(uint256 shares, uint256 minCollateralOut)
        public
        virtual
        nonReentrant
        seededOnly
        marketOpen
    {
        uint256 userShares = lpShares[msg.sender];

        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        uint256 yesOut = AMMLib.calculateProportionalOutput(yesReserve, shares, totalShares);
        uint256 noOut = AMMLib.calculateProportionalOutput(noReserve, shares, totalShares);

        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;
        yesReserve -= yesOut;
        noReserve -= noOut;

        emit MarketEvents.LiquidityRemoved(msg.sender, yesOut, noOut, shares);

        uint256 completeSets = yesOut < noOut ? yesOut : noOut;

        (uint256 netCollaterals, uint256 fee) = FeeLib.deductFee(
            completeSets, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS
        );

        if (netCollaterals < minCollateralOut) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded();
        }

        protocolCollateralFees += fee;

        yesToken.burn(address(this), completeSets);
        noToken.burn(address(this), completeSets);

        uint256 leftoverYes = yesOut - completeSets;
        uint256 leftoverNo = noOut - completeSets;

        if (leftoverYes > 0) {
            IERC20(address(yesToken)).safeTransfer(msg.sender, leftoverYes);
        }

        if (leftoverNo > 0) {
            IERC20(address(noToken)).safeTransfer(msg.sender, leftoverNo);
        }

        i_collateral.safeTransfer(msg.sender, netCollaterals);

        emit MarketEvents.CompleteSetsRedeemed(msg.sender, netCollaterals);
    }

    function withdrawLiquidityCollateral(uint256 shares) external nonReentrant whenNotPaused {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
        }

        uint256 resolutionOut = uint256(resolution);

        if (resolutionOut != uint256(Resolution.Yes) && resolutionOut != uint256(Resolution.No)) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        uint256 userShares = lpShares[msg.sender];

        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        _withdrawResolvedLiquidity(shares, userShares, resolutionOut == uint256(Resolution.Yes));
    }

    function transferShares(address to, uint256 shares) public virtual whenNotPaused {
        if (to == address(0)) {
            revert MarketErrors.PredictionMarket__TransferShares_CantbeSendtoZeroAddress();
        }
        if (lpShares[msg.sender] < shares) {
            revert MarketErrors.PredictionMarket__TransferShares_InsufficientShares();
        }

        lpShares[msg.sender] -= shares;
        lpShares[to] += shares;

        emit MarketEvents.SharesTransferred(msg.sender, to, shares);
    }

    function mintCompleteSets(uint256 amount) public virtual nonReentrant marketOpen zeroAmountCheck(amount) {
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__MintingCompleteset__AmountLessThanMinimu();
        }

        uint256 userCollateralBalance = i_collateral.balanceOf(msg.sender);
        if (userCollateralBalance < amount) {
            revert MarketErrors.PredictionMarket__MintCompleteSets_InsuffientTokenBalance();
        }

        uint256 exposure = userRiskExposure[msg.sender];
        if (msg.sender != address(marketFactory) && !isRiskExempt[msg.sender] && exposure + amount > MarketConstants.MAX_RISK_EXPOSURE) {
            revert MarketErrors.PredictionMarket__RiskExposureExceeded();
        }

        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.MINT_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        protocolCollateralFees += fee;
        userRiskExposure[msg.sender] += amount;

        i_collateral.safeTransferFrom(msg.sender, address(this), amount);

        yesToken.mint(msg.sender, netAmount);
        noToken.mint(msg.sender, netAmount);

        emit MarketEvents.CompleteSetsMinted(msg.sender, netAmount);
    }

    function redeemCompleteSets(uint256 amount) public virtual nonReentrant marketOpen zeroAmountCheck(amount) {
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__RedeemCompletesetLessThanMinAllowed();
        }
        uint256 userNoBalance = noToken.balanceOf(msg.sender);
        uint256 userYesBalance = yesToken.balanceOf(msg.sender);
        if (userNoBalance < amount || userYesBalance < amount) {
            revert MarketErrors.PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();
        }

        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        protocolCollateralFees += fee;

        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
        i_collateral.safeTransfer(msg.sender, netAmount);

        emit MarketEvents.CompleteSetsRedeemed(msg.sender, netAmount);
    }

    function swapYesForNo(uint256 yesIn, uint256 minNoOut)
        public
        virtual
        nonReentrant
        marketOpen
        seededOnly
        zeroAmountCheck(yesIn)
    {
        _swap(yesIn, minNoOut, true);
    }

    function swapNoForYes(uint256 noIn, uint256 minYesOut)
        public
        virtual
        nonReentrant
        marketOpen
        seededOnly
        zeroAmountCheck(noIn)
    {
        _swap(noIn, minYesOut, false);
    }

}
