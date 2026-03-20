// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MarketConstants,
    MarketEvents,
    MarketErrors,
    State,
    Resolution
} from "../libraries/MarketTypes.sol";
import {LMSRLib} from "../libraries/LMSRLib.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {OutcomeToken} from "../token/OutcomeToken.sol";
import {PredictionMarketBase} from "./PredictionMarketBase.sol";

/// @title PredictionMarketLiquidity
/// @notice LMSR trading, market initialization, and complete-set flows for an open market.
/// @dev All LMSR buy/sell trades are CRE-report-driven. The CRE HTTP handler computes
///      the cost using exp/ln off-chain, then sends a signed report that this contract validates
///      and executes. Complete-set mint/redeem remain direct user calls (AMM-agnostic).
abstract contract PredictionMarketLiquidity is PredictionMarketBase {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════
    //  LMSR Market Initialization
    // ═══════════════════════════════════════════════════════════════════

    /// @notice One-time LMSR market initialization. Locks collateral as market-maker subsidy.
    /// @dev The subsidy = b × ln(2) for binary markets. This collateral must be pre-funded
    ///      to this contract before calling. Unlike CPMM seedLiquidity, no LP shares are minted.
    ///      The market creator accepts bounded loss (subsidy amount) in exchange for providing
    ///      continuous liquidity to the market.
    /// @param _liquidityParam The LMSR 'b' parameter. Controls market depth and max loss.
    function initializeMarket(
        uint256 _liquidityParam
    ) external onlyOwner whenNotPaused {
        if (initialized) {
            revert MarketErrors.LMSR__AlreadyInitialized();
        }
        if (_liquidityParam == 0) {
            revert MarketErrors.PredictionMarket__AmountCantBeZero();
        }

        uint256 subsidyRequired = LMSRLib.maxSubsidyLoss(_liquidityParam);
        uint256 contractBalance = i_collateral.balanceOf(address(this));
        if (contractBalance < subsidyRequired) {
            revert MarketErrors.LMSR__InsufficientSubsidy();
        }

        liquidityParam = _liquidityParam;
        subsidyDeposit = subsidyRequired;
        initialized = true;

        // Initial shares are both zero → equal 50/50 pricing
        yesSharesOutstanding = 0;
        noSharesOutstanding = 0;
        lastYesPriceE6 = 500_000;
        lastNoPriceE6 = 500_000;
        tradeNonce = 0;

        emit MarketEvents.MarketInitialized(_liquidityParam, subsidyRequired);
    }





    // ═══════════════════════════════════════════════════════════════════
    //  CRE-Driven LMSR Trade Execution
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Executes an LMSR buy trade from a CRE-signed report.
    /// @dev Called internally by _processReport when action type is "LMSRBuy".
    ///      The CRE handler computed the cost off-chain using:
    ///        costDelta = C(q + Δe_i) - C(q) where C(q) = b × ln(Σ exp(q_j / b))
    ///      On-chain we validate: prices sum to ~1e6, nonce is fresh, amounts are sane.
    /// @param trader Address of the buyer (collateral taken from this address).
    /// @param outcomeIndex 0 for YES, 1 for NO.
    /// @param sharesDelta Number of outcome shares to mint.
    /// @param costDelta Collateral cost computed by CRE (pre-fee).
    /// @param newYesPriceE6 Updated YES price after trade (1e6 precision).
    /// @param newNoPriceE6 Updated NO price after trade (1e6 precision).
    /// @param nonce Monotonic trade nonce from CRE.
    function _executeLMSRBuy(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal marketOpen {
        // ── Validation ───────────────────────────────────────────────
        if (trader == address(0))
            revert MarketErrors.LMSR__TraderCannotBeZero();
        if (outcomeIndex > 1) revert MarketErrors.LMSR__InvalidOutcomeIndex();
        if (sharesDelta < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT)
            revert MarketErrors.LMSR__TradeBelowMinimum();
        if (!LMSRLib.validatePriceSum(newYesPriceE6, newNoPriceE6))
            revert MarketErrors.LMSR__InvalidPriceSum();
        if (!LMSRLib.validateTradeNonce(tradeNonce, nonce))
            revert MarketErrors.LMSR__StaleTradeNonce();
        uint256 effectiveFeeBps = _resolveLMSRTradeControls(
            outcomeIndex,
            true,
            costDelta,
            trader
        );
        // Extract fee from inclusive amount (CRE sends cost with fee already subtracted)
        uint256 fee = FeeLib.calculateFee(
            costDelta,
            effectiveFeeBps,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 actualCost = costDelta - fee; // costDelta is already inclusive (CRE subtracted fee)

        if (!isRiskExempt[trader]) {
            // Check exactly what we track as exposure to avoid fee-mismatch drift.
            _checkUserExposure(trader, actualCost);
        }

        // ── State update ─────────────────────────────────────────────
        tradeNonce += 1;
        lastYesPriceE6 = newYesPriceE6;
        lastNoPriceE6 = newNoPriceE6;

        protocolCollateralFees += fee;
        if (!isRiskExempt[trader]) {
            userRiskExposure[trader] += actualCost;
        }

    
        // Mint outcome tokens to trader and update outstanding shares
        if (outcomeIndex == 0) {
            yesSharesOutstanding += sharesDelta;
          
            yesToken.mint(trader, sharesDelta);
        } else {
            noSharesOutstanding += sharesDelta;
            noToken.mint(trader, sharesDelta);
        }

            // Transfer collateral (inclusive cost) from trader to market
        i_collateral.safeTransferFrom(trader, address(this), costDelta);


        emit MarketEvents.LMSRBuyExecuted(
            trader,
            outcomeIndex,
            sharesDelta,
            costDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );
    }


    /// @notice Validates that a user's total exposure does not exceed the dynamic risk cap.
    /// @dev Ensures user exposure stays within 5% of total market liquidity (500 BPS).
    ///      Reverts with RiskExposureExceeded if the new exposure would exceed the cap.
    ///      This protects the protocol from excessive concentration risk per user.
    /// @param user The address of the user to check exposure for.
    /// @param additionalExposure The additional exposure amount to add to current exposure.
    function _checkUserExposure(address user, uint256 additionalExposure) internal view {
       // Calculate the dynamic cap: (Liquidity * 500) / 10000
        uint256 dynamicCap = (liquidityParam * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        
        uint256 currentExposure = userRiskExposure[user];
        uint256 newExposure = currentExposure + additionalExposure;
        if (newExposure > dynamicCap) {
            revert MarketErrors.PredictionMarket__RiskExposureExceeded();
        }
    }




    /// @notice Executes an LMSR sell trade from a CRE-signed report.
    /// @dev Called internally by _processReport when action type is "LMSRSell".
    ///      The CRE handler computed the refund off-chain using:
    ///        refundDelta = C(q) - C(q - Δe_i)
    ///      Trader must hold >= sharesDelta of the outcome token.
    /// @param trader Address of the seller (refund sent to this address).
    /// @param outcomeIndex 0 for YES, 1 for NO.
    /// @param sharesDelta Number of outcome shares to burn.
    /// @param refundDelta Collateral refund computed by CRE (pre-fee).
    /// @param newYesPriceE6 Updated YES price after trade (1e6 precision).
    /// @param newNoPriceE6 Updated NO price after trade (1e6 precision).
    /// @param nonce Monotonic trade nonce from CRE.
    function _executeLMSRSell(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal marketOpen  {
        // ── Validation ───────────────────────────────────────────────
        if (trader == address(0))
            revert MarketErrors.LMSR__TraderCannotBeZero();
        if (outcomeIndex > 1) revert MarketErrors.LMSR__InvalidOutcomeIndex();
        if (sharesDelta < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT)
            revert MarketErrors.LMSR__TradeBelowMinimum();
        if (!LMSRLib.validatePriceSum(newYesPriceE6, newNoPriceE6))
            revert MarketErrors.LMSR__InvalidPriceSum();
        if (!LMSRLib.validateTradeNonce(tradeNonce, nonce))
            revert MarketErrors.LMSR__StaleTradeNonce();
        uint256 effectiveFeeBps = _resolveLMSRTradeControls(
            outcomeIndex,
            false,
            refundDelta,
            trader
        );
     if(!isRiskExempt[trader]){
            userRiskExposure[trader] = userRiskExposure[trader] > refundDelta
            ? userRiskExposure[trader] - refundDelta
            : 0; // Prevent underflow  
     }
        // Check router has enough tokens to sell
        OutcomeToken token = outcomeIndex == 0 ? yesToken : noToken;





        if (token.balanceOf(trader) < sharesDelta)
            revert MarketErrors.LMSR__InsufficientShares();

     

        // ── State update ─────────────────────────────────────────────
        tradeNonce += 1;
        lastYesPriceE6 = newYesPriceE6;
        lastNoPriceE6 = newNoPriceE6;

        // Burn outcome tokens from router and update outstanding shares
        if (outcomeIndex == 0) {
            yesSharesOutstanding -= sharesDelta;
          
            yesToken.burn(trader, sharesDelta);
        } else {
            noSharesOutstanding -= sharesDelta;
          
            noToken.burn(trader, sharesDelta);
        }

        // Extract fee from inclusive refund (CRE sends refund with fee already subtracted)
        uint256 fee = FeeLib.calculateFee(
            refundDelta,
            effectiveFeeBps,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 netRefund = refundDelta - fee; // refundDelta is already inclusive (CRE subtracted fee)
        protocolCollateralFees += fee;

        // Transfer net collateral refund to trader
        i_collateral.safeTransfer(trader, netRefund);

        emit MarketEvents.LMSRSellExecuted(
            trader,
            outcomeIndex,
            sharesDelta,
            refundDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );
    }

    function _resolveLMSRTradeControls(
        uint8 outcomeIndex,
        bool isBuy,
        uint256 tradeNotional,
        address trader
    ) internal view returns (uint256 effectiveFeeBps) {
        effectiveFeeBps = MarketConstants.LMSR_TRADE_FEE_BPS;

        if (!_isCanonicalPricingMode()) {
            return effectiveFeeBps;
        }

/// @dev Rejects canonical prices that are zero on either side.
      if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
         /// @dev Rejects missing or expired canonical price snapshots.
         if (canonicalPriceNonce == 0 || block.timestamp > canonicalPriceValidUntil) {
            revert PredictionMarket__CanonicalPriceStale();
        }
       

        bool yesForNo = isBuy ? outcomeIndex == 1 : outcomeIndex == 0;
        uint256 collateralReserve = i_collateral.balanceOf(address(this));

        CanonicalPricingModule.SwapControlsParams
            memory p = CanonicalPricingModule.SwapControlsParams({
                yesForNo: yesForNo,
                reserveOut: collateralReserve,
                localYesPriceE6: lastYesPriceE6,
                pricePrecision: MarketConstants.PRICE_PRECISION,
                canonicalYesPriceE6: canonicalYesPriceE6,
                softDeviationBps: softDeviationBps,
                stressDeviationBps: stressDeviationBps,
                hardDeviationBps: hardDeviationBps,
                stressExtraFeeBps: stressExtraFeeBps,
                stressMaxOutBps: stressMaxOutBps,
                unsafeMaxOutBps: unsafeMaxOutBps,
                swapFeeBps: MarketConstants.LMSR_TRADE_FEE_BPS,
                feePrecisionBps: MarketConstants.FEE_PRECISION_BPS
            });
        uint256 maxOut;
        (, effectiveFeeBps, maxOut, ) = CanonicalPricingModule.swapControls(p);

        if (trader != address(marketFactory) && tradeNotional > maxOut) {
            revert PredictionMarket__TradeSizeExceedsBandLimit();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Complete Set Operations (AMM-agnostic, works with any model)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Mints complete sets by depositing collateral.
    /// @dev Economic effect:
    /// - user deposits `amount` collateral,
    /// - protocol takes mint fee,
    /// - user receives equal YES and NO balances of `netAmount`.
    /// Risk control:
    /// user exposure is tracked and bounded unless caller is factory or explicitly exempt.
    function mintCompleteSets(
        uint256 amount
    )
        public
        virtual
        nonReentrant
        marketOpen
       
       
    {
        _initializedOnly();
        _zeroAmountCheck(amount);
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__MintingCompleteSet__AmountLessThanMinimum();
        }

        uint256 userCollateralBalance = i_collateral.balanceOf(msg.sender);
        if (userCollateralBalance < amount) {
            revert MarketErrors.PredictionMarket__MintCompleteSets_InsufficientTokenBalance();
        }

    
        if (
            msg.sender != address(marketFactory) &&
            msg.sender != routerVault &&
            !isRiskExempt[msg.sender]
        ) {
            _checkUserExposure(msg.sender, amount);
        }

        (uint256 netAmount, uint256 fee) = FeeLib.deductFee(
            amount,
            MarketConstants.MINT_COMPLETE_SETS_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );

        protocolCollateralFees += fee;
        
        if (msg.sender != routerVault && !isRiskExempt[msg.sender]) {
            userRiskExposure[msg.sender] += amount;
        }

        i_collateral.safeTransferFrom(msg.sender, address(this), amount);

        yesToken.mint(msg.sender, netAmount);
        noToken.mint(msg.sender, netAmount);
        yesSharesOutstanding += netAmount;
        noSharesOutstanding += netAmount;


        emit MarketEvents.CompleteSetsMinted(msg.sender, netAmount);
    }

    /// @notice Redeems complete sets back into collateral during open market state.
    /// @dev Caller must hold both sides in equal `amount`. Contract burns both tokens,
    /// charges redeem fee, and transfers net collateral back to caller.
    function redeemCompleteSets(
        uint256 amount
    ) public virtual nonReentrant marketOpen {
        _zeroAmountCheck(amount);
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__RedeemCompleteSetLessThanMinAllowed();
        }
        uint256 userNoBalance = noToken.balanceOf(msg.sender);
        uint256 userYesBalance = yesToken.balanceOf(msg.sender);
        if (userNoBalance < amount || userYesBalance < amount) {
            revert MarketErrors.PredictionMarket__RedeemCompleteSets_InsufficientTokenBalance();
        }

        (uint256 netAmount, uint256 fee) = FeeLib.deductFee(
            amount,
            MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );

        protocolCollateralFees += fee;
        if (msg.sender != routerVault && !isRiskExempt[msg.sender]) {
            userRiskExposure[msg.sender] = userRiskExposure[msg.sender] > amount
                ? userRiskExposure[msg.sender] - amount
                : 0;
        }
        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
        yesSharesOutstanding = yesSharesOutstanding > amount ? yesSharesOutstanding - amount : 0;
        noSharesOutstanding = noSharesOutstanding > amount ? noSharesOutstanding - amount : 0;
        i_collateral.safeTransfer(msg.sender, netAmount);

        emit MarketEvents.CompleteSetsRedeemed(msg.sender, netAmount);
    }

    /// @notice External entry point for executing LMSR buy trades via router vault.
    /// @dev Only callable by the authorized router vault. Validates CRE report data and executes trade.
    function executeBuy(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) external onlyRouterVaultAndFactory(trader) nonReentrant {
        _executeLMSRBuy(
            trader,
            outcomeIndex,
            sharesDelta,
            costDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );
    }


    /// @notice External entry point for executing LMSR sell trades via router vault.
    /// @dev Only callable by the authorized router vault. Validates CRE report data and executes trade.
    function executeSell(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) external onlyRouterVaultAndFactory(trader) nonReentrant {
        _executeLMSRSell(
            trader,
            outcomeIndex,
            sharesDelta,
            refundDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );
    }
}
