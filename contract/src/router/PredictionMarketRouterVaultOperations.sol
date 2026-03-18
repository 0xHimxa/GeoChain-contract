// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketConstants} from "../libraries/MarketTypes.sol";
import {
    PredictionMarketRouterVaultBase,
    IPredictionMarketLike
} from "./PredictionMarketRouterVaultBase.sol";
import {FeeLib} from "../libraries/FeeLib.sol";

/// @title PredictionMarketRouterVaultOperations
/// @notice User-facing actions and report-driven execution logic for router vault accounting.
abstract contract PredictionMarketRouterVaultOperations is
    PredictionMarketRouterVaultBase
{
    using SafeERC20 for IERC20;

    // ============================================================
    // External User/Admin Operations
    // ============================================================

    /// @notice Grants or updates agent permissions for caller-owned credits.
    function setAgentPermission(
        address agent,
        uint32 actionMask,
        uint128 maxAmountPerAction,
        uint64 expiresAt
    ) external {
        if (agent == address(0)) revert Router__ZeroAddress();
        if (expiresAt <= block.timestamp)
            revert Router__AgentPermissionExpired();
        if (actionMask == 0) revert Router__AgentActionNotAllowed();
        if (maxAmountPerAction == 0) revert Router__InvalidAmount();

        agentPermissions[msg.sender][agent] = AgentPermission({
            enabled: true,
            expiresAt: expiresAt,
            maxAmountPerAction: maxAmountPerAction,
            actionMask: actionMask
        });

        emit AgentPermissionUpdated(
            msg.sender,
            agent,
            true,
            actionMask,
            maxAmountPerAction,
            expiresAt
        );
    }

    /// @notice Revokes an agent immediately for caller-owned credits.
    function revokeAgentPermission(address agent) external {
        _revokeAgentPermission(msg.sender, agent);
    }

    /// @notice Allows or blocks a market for router operations.
    /// @dev Callable by owner or linked market factory only.
    function setMarketAllowed(address market, bool allowed) external {
        if (msg.sender != marketFactory && msg.sender != owner()) {
            revert PredictionMarketRouterVault__NotAuthorizedMarketMapper();
        }
        if (market == address(0)) revert Router__ZeroAddress();
        allowedMarkets[market] = allowed;
        emit MarketAllowlistUpdated(market, allowed);
    }

    /// @notice Sets whether an account bypasses risk-exposure limits.
    function setRiskExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert Router__ZeroAddress();
        isRiskExempt[account] = exempt;
        emit RouterRiskExemptUpdated(account, exempt);
    }

    /// @notice Withdraws native ETH held by the router to a recipient.
    /// @dev Owner-only emergency/admin path for ETH sent to the router (e.g. via receive()).
    function withdrawEth(
        address payable recipient,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert Router__ZeroAddress();
        if (amount == 0) revert Router__InvalidAmount();
        if (address(this).balance < amount)
            revert Router__InsufficientBalance();

        (bool ok, ) = recipient.call{value: amount}("");
        if (!ok) revert Router__EthTransferFailed();
        emit EthWithdrawn(recipient, amount);
    }

    /// @notice Deposits caller collateral and credits the caller.
    function depositCollateral(uint256 amount) external nonReentrant {
        _depositCollateral(msg.sender, msg.sender, amount);
    }

    /// @notice Deposits caller collateral and credits a beneficiary.
    function depositFor(
        address beneficiary,
        uint256 amount
    ) external nonReentrant {
        if (beneficiary == address(0)) revert Router__ZeroAddress();
        _depositCollateral(msg.sender, beneficiary, amount);
    }

    /// @notice Withdraws caller collateral credits back to wallet collateral.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        _withdrawCollateral(msg.sender, amount);
    }

    /// @notice Withdraws caller outcome-token credits to wallet.
    function withdrawOutcomeToken(
        address token,
        uint256 amount
    ) external nonReentrant {
        _withdrawOutcomeToken(msg.sender, token, amount);
    }

    /// @notice Mints complete sets in an allowlisted market using caller collateral credits.
    function mintCompleteSets(
        address market,
        uint256 amount
    ) external nonReentrant {
        _mintCompleteSets(msg.sender, market, amount);
    }

    /// @notice Redeems complete sets for collateral in an allowlisted market.
    function redeemCompleteSets(
        address market,
        uint256 amount
    ) external nonReentrant {
        _redeemCompleteSets(msg.sender, market, amount);
    }

    /// @notice Redeems winning outcome tokens after market resolution.
    function redeem(address market, uint256 amount) external nonReentrant {
        _redeem(msg.sender, market, amount);
    }

    // NOTE: External buy/sell removed - only CRE via _processReport can call these
    // LMSR trades are CRE-report-driven (off-chain compute, on-chain execute).
    // Users interact via: mintCompleteSets, redeemCompleteSets, redeem.

    /// @notice Submits a dispute against proposed market resolution.
    function disputeProposedResolution(
        address market,
        uint8 proposedOutcome
    ) external nonReentrant {
        _disputeProposedResolution(msg.sender, market, proposedOutcome);
    }

    // ============================================================
    // External Agent-Delegated Operations
    // ============================================================

    /// @notice Agent execution path for mint complete sets on behalf of a user.
    function mintCompleteSetsFor(
        address user,
        address market,
        uint256 amount
    ) external nonReentrant {
        _authorizeAgent(user, msg.sender, AGENT_ACTION_MINT, amount);
        _mintCompleteSets(user, market, amount);
        emit AgentActionExecuted(
            user,
            msg.sender,
            "routerAgentMintCompleteSets",
            amount
        );
    }

    /// @notice Agent execution path for redeem complete sets on behalf of a user.
    function redeemCompleteSetsFor(
        address user,
        address market,
        uint256 amount
    ) external nonReentrant {
        _authorizeAgent(
            user,
            msg.sender,
            AGENT_ACTION_REDEEM_COMPLETE_SETS,
            amount
        );
        _redeemCompleteSets(user, market, amount);
        emit AgentActionExecuted(
            user,
            msg.sender,
            "routerAgentRedeemCompleteSets",
            amount
        );
    }

    // NOTE: Agent swap/LP functions removed in LMSR mode.
    // LMSR trades are CRE-driven, not direct user/agent calls.

    /// @notice Agent execution path for redeem winnings on behalf of a user.
    function redeemFor(
        address user,
        address market,
        uint256 amount
    ) external nonReentrant {
        _authorizeAgent(user, msg.sender, AGENT_ACTION_REDEEM_WINNINGS, amount);
        _redeem(user, market, amount);
        emit AgentActionExecuted(user, msg.sender, "routerAgentRedeem", amount);
    }

    /// @notice Agent execution path for dispute submission on behalf of a user.
    function disputeProposedResolutionFor(
        address user,
        address market,
        uint8 proposedOutcome
    ) external nonReentrant {
        _authorizeAgent(user, msg.sender, AGENT_ACTION_DISPUTE, 0);
        _disputeProposedResolution(user, market, proposedOutcome);
        emit AgentActionExecuted(
            user,
            msg.sender,
            "routerAgentDisputeProposedResolution",
            0
        );
    }

    // ============================================================
    // Internal Accounting + Market Operations
    // ============================================================

    /// @dev Pulls collateral from payer and credits beneficiary in router accounting.
    function _depositCollateral(
        address payer,
        address beneficiary,
        uint256 amount
    ) internal {
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(payer, address(this), amount);
        uint256 balanceAfter = collateralToken.balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert Router__InvalidDelta();
        uint256 balanceDelta = balanceAfter - balanceBefore;
        collateralCredits[beneficiary] += balanceDelta;
        totalCollateralCredits += balanceDelta;
        emit Deposited(beneficiary, balanceDelta);
    }

    /// @dev Burns user collateral credits and transfers collateral out.
    function _withdrawCollateral(address user, uint256 amount) internal {
        uint256 bal = collateralCredits[user];
        if (bal < amount) revert Router__InsufficientBalance();
        collateralCredits[user] = bal - amount;
        totalCollateralCredits -= amount;
        collateralToken.safeTransfer(user, amount);
        emit CollateralWithdrawn(user, amount);
    }

    /// @dev Burns user outcome-token credits and transfers tokens out.
    function _withdrawOutcomeToken(
        address user,
        address token,
        uint256 amount
    ) internal {
        uint256 bal = tokenCredits[user][token];
        if (bal < amount) revert Router__InsufficientBalance();
        tokenCredits[user][token] = bal - amount;
        IERC20(token).safeTransfer(user, amount);
        emit OutcomeWithdrawn(user, token, amount);
    }

    /// @dev Verifies enough untracked collateral exists to issue new credits safely.
    /// This prevents the router from minting accounting credits against collateral that is already
    /// backing user balances tracked in `totalCollateralCredits`.
    function _creditFromUntrackedCollateral(
        address user,
        uint256 amount
    ) internal view {
        if (user == address(0)) revert Router__ZeroAddress();
        if (amount == 0) revert Router__InvalidAmount();

        uint256 balance = collateralToken.balanceOf(address(this));
        uint256 credited = totalCollateralCredits;
        uint256 untracked = balance > credited ? balance - credited : 0;
        if (untracked < amount)
            revert Router__InsufficientUntrackedCollateral();
    }

    /// @dev Credits user collateral from off-chain fiat settlement funds.
    function _creditCollateralFromFiat(address user, uint256 amount) internal {
        _creditFromUntrackedCollateral(user, amount);
        collateralCredits[user] += amount;
        totalCollateralCredits += amount;
        emit CollateralCreditedFromFiat(user, amount);
    }

    /// @dev Credits user collateral from ETH deposit flow with replay protection by depositId.
    function _creditCollateralFromEth(
        address user,
        uint256 amount,
        bytes32 depositId
    ) internal {
        if (depositId == bytes32(0)) revert Router__InvalidDepositId();
        if (processedEthDeposits[depositId])
            revert Router__EthDepositAlreadyProcessed();
        _creditFromUntrackedCollateral(user, amount);
        processedEthDeposits[depositId] = true;
        collateralCredits[user] += amount;
        totalCollateralCredits += amount;
        emit CollateralCreditedFromEth(user, amount, depositId);
    }

    /// @dev Executes market mint flow, moving collateral credits into YES/NO token credits.
    function _mintCompleteSets(
        address user,
        address market,
        uint256 amount
    ) internal {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        if (!isRiskExempt[user]) {
            _checkUserExposure(user, market, amount);
        }

        uint256 userCollateral = collateralCredits[user];
        if (userCollateral < amount) revert Router__InsufficientBalance();
        collateralCredits[user] = userCollateral - amount;
        totalCollateralCredits -= amount;

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

        if (!isRiskExempt[user]) {
            uint256 exposure = userRiskExposure[user];
            userRiskExposure[user] = exposure + amount;
        }
        tokenCredits[user][yes] += yesDelta;
        tokenCredits[user][no] += noDelta;

        emit CompleteSetsMinted(user, market, amount, yesDelta, noDelta);
    }

    /// @dev Executes complete-set redemption flow, returning collateral credits to user.
    function _redeemCompleteSets(
        address user,
        address market,
        uint256 amount
    ) internal {
        _validateMarket(market);
        address yes = IPredictionMarketLike(market).yesToken();
        address no = IPredictionMarketLike(market).noToken();

        uint256 yesBal = tokenCredits[user][yes];
        uint256 noBal = tokenCredits[user][no];
        if (yesBal < amount || noBal < amount)
            revert Router__InsufficientBalance();
        tokenCredits[user][yes] = yesBal - amount;
        tokenCredits[user][no] = noBal - amount;

 // If we didn't reduce this, a user could:
    //   1. Buy 100 YES via AMM  → userAMMBoughtShares[YES] = 100
    //   2. Mint 100 complete sets → tokenCredits[YES] = 200, tokenCredits[NO] = 100
    //   3. Redeem 100 complete sets (burns 100 YES + 100 NO)
    //   4. userAMMBoughtShares[YES] still = 100 — but they only hold 100 YES total
    //   5. They could then sell 100 YES to AMM — draining the market incorrectly
    //      since those 100 YES are the minted ones, not AMM-bought ones.

    uint256 yesAMM = userAMMBoughtShares[user][market][0];
    uint256 noAMM  = userAMMBoughtShares[user][market][1];

    // Reduce YES AMM balance by up to `amount`, floor at 0
if (yesAMM > 0) {
    userAMMBoughtShares[user][market][0] = yesAMM > amount ? yesAMM - amount : 0;
}
// Reduce NO AMM balance by up to `amount`, floor at 0
if (noAMM > 0) {
    userAMMBoughtShares[user][market][1] = noAMM > amount ? noAMM - amount : 0;
}
    
  


        uint256 collateralBefore = collateralToken.balanceOf(address(this));
        _ensureAllowance(IERC20(yes), market, amount);
        _ensureAllowance(IERC20(no), market, amount);
        IPredictionMarketLike(market).redeemCompleteSets(amount);
        uint256 collateralAfter = collateralToken.balanceOf(address(this));

        if (collateralAfter < collateralBefore) revert Router__InvalidDelta();
        uint256 collateralDelta = collateralAfter - collateralBefore;
        collateralCredits[user] += collateralDelta;
        totalCollateralCredits += collateralDelta;
        uint256 exposure = userRiskExposure[user];
        userRiskExposure[user] = exposure > amount ? exposure - amount : 0;

        emit CompleteSetsRedeemed(user, market, amount, collateralDelta);
    }

    /// @dev Redeems winning outcome tokens for collateral after market resolution.
    function _redeem(address user, address market, uint256 amount) internal {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        uint8 marketResolution = IPredictionMarketLike(market).resolution();
        address winningToken;

        if (marketResolution == 1) {
            winningToken = IPredictionMarketLike(market).yesToken();
        } else if (marketResolution == 2) {
            winningToken = IPredictionMarketLike(market).noToken();
        } else {
            revert Router__MarketNotResolved();
        }

        uint256 winningBal = tokenCredits[user][winningToken];
        if (winningBal < amount) revert Router__InsufficientBalance();
        tokenCredits[user][winningToken] = winningBal - amount;

        uint256 collateralBefore = collateralToken.balanceOf(address(this));
        _ensureAllowance(IERC20(winningToken), market, amount);
        IPredictionMarketLike(market).redeem(amount);
        uint256 collateralAfter = collateralToken.balanceOf(address(this));

        if (collateralAfter < collateralBefore) revert Router__InvalidDelta();
        uint256 collateralDelta = collateralAfter - collateralBefore;
        collateralCredits[user] += collateralDelta;
        totalCollateralCredits += collateralDelta;
        uint256 exposure = userRiskExposure[user];
        userRiskExposure[user] = exposure > amount ? exposure - amount : 0;

        emit WinningsRedeemed(user, market, amount, collateralDelta);
    }

    /// @dev Executes LMSR buy trade via router vault accounting.
    function _buy(
        address user,
        address market,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        uint256 actualCost = costDelta;
        if (!isRiskExempt[user]) {
            uint256 fee = FeeLib.calculateFee(
                costDelta,
                MarketConstants.LMSR_TRADE_FEE_BPS,
                MarketConstants.FEE_PRECISION_BPS
            );
            actualCost = costDelta - fee;
            _checkUserExposure(user, market, actualCost);
        }

        // costDelta is inclusive (CRE already subtracted fee)
        uint256 userCollateral = collateralCredits[user];
        if (userCollateral < costDelta) revert Router__InsufficientBalance();
        collateralCredits[user] = userCollateral - costDelta;
        totalCollateralCredits -= costDelta;

        address token = outcomeIndex == 0
            ? IPredictionMarketLike(market).yesToken()
            : IPredictionMarketLike(market).noToken();

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));


        _ensureAllowance(collateralToken, market, costDelta);
        IPredictionMarketLike(market).executeBuy(
           address(this),
            outcomeIndex,
            sharesDelta,
            costDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );

        uint256 tokenAfter = IERC20(token).balanceOf(address(this));
        uint256 tokenDelta = tokenAfter - tokenBefore;

            // ── Track AMM-bought shares per user for sell validation ──────
    // Only shares purchased through the AMM are eligible for AMM sells.
    // Minted complete sets are NOT counted here.
        userAMMBoughtShares[user][market][outcomeIndex] += tokenDelta;

        tokenCredits[user][token] += tokenDelta;
        if (!isRiskExempt[user]) {
            uint256 exposure = userRiskExposure[user];
            userRiskExposure[user] = exposure + actualCost;
        }

        emit BoughtSideCompleted(user, market, costDelta, tokenDelta);
    }
 
    /// @dev Executes LMSR sell trade via router vault accounting.
    function _sell(
        address user,
        address market,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal {
        _validateMarket(market);

        address token = outcomeIndex == 0
            ? IPredictionMarketLike(market).yesToken()
            : IPredictionMarketLike(market).noToken();

        uint256 userTokenBal = tokenCredits[user][token];
        if (userTokenBal < sharesDelta) revert Router__InsufficientBalance();


    // ── Guard: of those tokens, only AMM-bought shares may be sold back
    //    to the AMM. Minted complete sets must go through redeemCompleteSets.
    uint256 availableAMMShares = userAMMBoughtShares[user][market][outcomeIndex];
    if (sharesDelta > availableAMMShares) revert Router__InsufficientAMMBoughtShares();


    // Deduct from AMM-bought tracker so accounting stays consistent
    userAMMBoughtShares[user][market][outcomeIndex] = availableAMMShares - sharesDelta;
        tokenCredits[user][token] = userTokenBal - sharesDelta;

        uint256 collateralBefore = collateralToken.balanceOf(address(this));

        _ensureAllowance(IERC20(token), market, sharesDelta);
        IPredictionMarketLike(market).executeSell(
            address(this),
            outcomeIndex,
            sharesDelta,
            refundDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );

        uint256 collateralAfter = collateralToken.balanceOf(address(this));
        uint256 collateralDelta = collateralAfter - collateralBefore;

        collateralCredits[user] += collateralDelta;
        totalCollateralCredits += collateralDelta;
        if (!isRiskExempt[user]) {
            uint256 exposure = userRiskExposure[user];
            userRiskExposure[user] = exposure > refundDelta
                ? exposure - refundDelta
                : 0;
        }

        emit SideSoldCompleted(user, market, sharesDelta, collateralDelta);
    }

    /// @notice Validates that a user's total exposure does not exceed the dynamic risk cap.
    /// @dev Ensures user exposure stays within 5% of total market liquidity (500 BPS).
    ///      Reverts with Router__RiskExposureExceeded if the new exposure would exceed the cap.
    /// @param user The address of the user to check exposure for.
    /// @param market The market used to derive the dynamic cap.
    /// @param additionalExposure The additional exposure amount to add to current exposure.
    function _checkUserExposure(
        address user,
        address market,
        uint256 additionalExposure
    ) internal view {
        uint256 liquidityParam = IPredictionMarketLike(market).liquidityParam();
        if (liquidityParam == 0) {
            revert Router__MarketNotInitialized();
        }
        uint256 dynamicCap = (liquidityParam *
            MarketConstants.MAX_EXPOSURE_BPS) /
            MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 currentExposure = userRiskExposure[user];
        if (currentExposure + additionalExposure > dynamicCap) {
            revert Router__RiskExposureExceeded();
        }
    }

    // NOTE: _swapYesForNo, _swapNoForYes, _addLiquidity, _removeLiquidity
    // removed in LMSR mode. Trades are CRE-report-driven.

    /// @dev Forwards user dispute intent to market contract.
    function _disputeProposedResolution(
        address user,
        address market,
        uint8 proposedOutcome
    ) internal {
        _validateMarket(market);
        IPredictionMarketLike(market).disputeProposedResolution(
           user, proposedOutcome
        );
        emit DisputeSubmitted(user, market, proposedOutcome);
    }

    // ============================================================
    // Internal Agent Permission Utilities
    // ============================================================

    /// @dev Clears delegated agent permission for a specific user-agent pair.
    function _revokeAgentPermission(address user, address agent) internal {
        if (agent == address(0)) revert Router__ZeroAddress();
        delete agentPermissions[user][agent];
        emit AgentPermissionRevoked(user, agent);
    }

    /// @dev Verifies delegated agent permissions configured by user.
    /// The `boundedAmount` is action-specific:
    /// - direct trade amount for swaps/mints/redeems,
    /// - max(yes,no) for add-liquidity,
    /// - zero for disputes.
    function _authorizeAgent(
        address user,
        address agent,
        uint32 actionBit,
        uint256 boundedAmount
    ) internal view {
        AgentPermission memory permission = agentPermissions[user][agent];
        if (!permission.enabled) revert Router__AgentNotAuthorized();
        if (permission.expiresAt < block.timestamp)
            revert Router__AgentPermissionExpired();
        if ((permission.actionMask & actionBit) == 0)
            revert Router__AgentActionNotAllowed();
        if (boundedAmount > permission.maxAmountPerAction)
            revert Router__AgentAmountExceeded();
    }

    // ============================================================
    // Internal Report Dispatch
    // ============================================================

    /// @dev Returns max(a,b) as the bounded amount for add-liquidity authorization.
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @dev Handles non-agent router action reports.
    /// Payload shape depends on actionType and mirrors each internal operation signature.
    /// Returns `true` when the hash matched a known router action so the caller can continue
    /// dispatching agent-only actions only when needed.
    function _dispatchRouterAction(
        bytes32 actionTypeHash,
        bytes memory payload
    ) internal returns (bool) {
        if (actionTypeHash == HASHED_DEPOSIT_FOR) {
            (address user, uint256 amount) = abi.decode(
                payload,
                (address, uint256)
            );
            _depositCollateral(user, user, amount);
            return true;
        }
        if (actionTypeHash == HASHED_WITHDRAW_COLLATERAL) {
            (address user, uint256 amount) = abi.decode(
                payload,
                (address, uint256)
            );
            _withdrawCollateral(user, amount);
            return true;
        }
        if (actionTypeHash == HASHED_WITHDRAW_OUTCOME) {
            (address user, address token, uint256 amount) = abi.decode(
                payload,
                (address, address, uint256)
            );
            _withdrawOutcomeToken(user, token, amount);
            return true;
        }
        if (actionTypeHash == HASHED_MINT) {
            (address user, address market, uint256 amount) = abi.decode(
                payload,
                (address, address, uint256)
            );
            _mintCompleteSets(user, market, amount);
            return true;
        }
        if (actionTypeHash == HASHED_REDEEM) {
            (address user, address market, uint256 amount) = abi.decode(
                payload,
                (address, address, uint256)
            );
            _redeemCompleteSets(user, market, amount);
            return true;
        }
        if (actionTypeHash == HASHED_BUY) {
            (
                address user,
                address market,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 costDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                payload,
                (address, address, uint8, uint256, uint256, uint256, uint256, uint64)
            );
            _buy(user, market, outcomeIndex, sharesDelta, costDelta, newYesPriceE6, newNoPriceE6, nonce);
            return true;
        }
        if (actionTypeHash == HASHED_SELL) {
            (
                address user,
                address market,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 refundDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                payload,
                (address, address, uint8, uint256, uint256, uint256, uint256, uint64)
            );
            _sell(user, market, outcomeIndex, sharesDelta, refundDelta, newYesPriceE6, newNoPriceE6, nonce);
            return true;
        }
        // NOTE: HASHED_SWAP_YES_FOR_NO, HASHED_SWAP_NO_FOR_YES, HASHED_ADD_LIQ, HASHED_REMOVE_LIQ
        // removed in LMSR mode. Trades are CRE-report-driven.
        if (actionTypeHash == HASHED_CREDIT_FROM_FIAT) {
            (address user, uint256 amount) = abi.decode(
                payload,
                (address, uint256)
            );
            _creditCollateralFromFiat(user, amount);
            return true;
        }
        if (actionTypeHash == HASHED_CREDIT_FROM_ETH) {
            (address user, uint256 amount, bytes32 depositId) = abi.decode(
                payload,
                (address, uint256, bytes32)
            );
            _creditCollateralFromEth(user, amount, depositId);
            return true;
        }
        if (actionTypeHash == HASHED_REDEEM_WINNINGS) {
            (address user, address market, uint256 amount) = abi.decode(
                payload,
                (address, address, uint256)
            );
            _redeem(user, market, amount);
            return true;
        }
        if (actionTypeHash == HASHED_DISPUTE) {
            (address user, address market, uint8 proposedOutcome) = abi.decode(
                payload,
                (address, address, uint8)
            );
            _disputeProposedResolution(user, market, proposedOutcome);
            return true;
        }
        return false;
    }

    /// @dev Handles agent action reports and emits standardized `AgentActionExecuted`.
    function _dispatchRouterAgentAction(
        bytes32 actionTypeHash,
        string memory actionType,
        bytes memory payload
    ) internal returns (bool) {
        if (actionTypeHash == HASHED_AGENT_MINT) {
            (address user, address agent, address market, uint256 amount) = abi
                .decode(payload, (address, address, address, uint256));
            _authorizeAgent(user, agent, AGENT_ACTION_MINT, amount);
            _mintCompleteSets(user, market, amount);
            emit AgentActionExecuted(user, agent, actionType, amount);
            return true;
        }
        if (actionTypeHash == HASHED_AGENT_REDEEM) {
            (address user, address agent, address market, uint256 amount) = abi
                .decode(payload, (address, address, address, uint256));
            _authorizeAgent(
                user,
                agent,
                AGENT_ACTION_REDEEM_COMPLETE_SETS,
                amount
            );
            _redeemCompleteSets(user, market, amount);
            emit AgentActionExecuted(user, agent, actionType, amount);
            return true;
        }
        // NOTE: Agent swap/LP dispatch entries removed in LMSR mode.
        if (actionTypeHash == HASHED_AGENT_REDEEM_WINNINGS) {
            (address user, address agent, address market, uint256 amount) = abi
                .decode(payload, (address, address, address, uint256));
            _authorizeAgent(user, agent, AGENT_ACTION_REDEEM_WINNINGS, amount);
            _redeem(user, market, amount);
            emit AgentActionExecuted(user, agent, actionType, amount);
            return true;
        }
        if (actionTypeHash == HASHED_AGENT_DISPUTE) {
            (
                address user,
                address agent,
                address market,
                uint8 proposedOutcome
            ) = abi.decode(payload, (address, address, address, uint8));
            _authorizeAgent(user, agent, AGENT_ACTION_DISPUTE, 0);
            _disputeProposedResolution(user, market, proposedOutcome);
            emit AgentActionExecuted(user, agent, actionType, 0);
            return true;
        }
        if (actionTypeHash == HASHED_AGENT_BUY) {
            (
                address user,
                address agent,
                address market,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 costDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                payload,
                (address, address, address, uint8, uint256, uint256, uint256, uint256, uint64)
            );
            _authorizeAgent(user, agent, AGENT_ACTION_BUY, costDelta);
            _buy(user, market, outcomeIndex, sharesDelta, costDelta, newYesPriceE6, newNoPriceE6, nonce);
            emit AgentActionExecuted(user, agent, actionType, costDelta);
            return true;
        }
        if (actionTypeHash == HASHED_AGENT_SELL) {
            (
                address user,
                address agent,
                address market,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 refundDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                payload,
                (address, address, address, uint8, uint256, uint256, uint256, uint256, uint64)
            );
            _authorizeAgent(user, agent, AGENT_ACTION_SELL, sharesDelta);
            _sell(user, market, outcomeIndex, sharesDelta, refundDelta, newYesPriceE6, newNoPriceE6, nonce);
            emit AgentActionExecuted(user, agent, actionType, sharesDelta);
            return true;
        }
        if (actionTypeHash == HASHED_AGENT_REVOKE_PERMISSION) {
            (address user, address agent) = abi.decode(
                payload,
                (address, address)
            );
            _revokeAgentPermission(user, agent);
            return true;
        }
        return false;
    }

    /// @dev Dispatches receiver reports by action hash into router operations.
    /// Report shape is `(string actionType, bytes payload)`.
    function _processReport(
        bytes calldata report
    ) internal override nonReentrant {
        (string memory actionType, bytes memory payload) = abi.decode(
            report,
            (string, bytes)
        );
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));
        if (_dispatchRouterAction(actionTypeHash, payload)) return;
        if (_dispatchRouterAgentAction(actionTypeHash, actionType, payload))
            return;
        revert Router__ActionNotRecognized();
    }
}
