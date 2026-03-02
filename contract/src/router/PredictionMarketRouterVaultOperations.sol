// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketConstants} from "../libraries/MarketTypes.sol";
import {PredictionMarketRouterVaultBase, IPredictionMarketLike} from "./PredictionMarketRouterVaultBase.sol";

/// @title PredictionMarketRouterVaultOperations
/// @notice User-facing actions and report-driven execution logic for router vault accounting.
abstract contract PredictionMarketRouterVaultOperations is PredictionMarketRouterVaultBase {
    using SafeERC20 for IERC20;

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

    /// @notice Deposits caller collateral and credits the caller.
    function depositCollateral(uint256 amount) external nonReentrant {
        _depositCollateral(msg.sender, msg.sender, amount);
    }

    /// @notice Deposits caller collateral and credits a beneficiary.
    function depositFor(address beneficiary, uint256 amount) external nonReentrant {
        if (beneficiary == address(0)) revert Router__ZeroAddress();
        _depositCollateral(msg.sender, beneficiary, amount);
    }

    /// @notice Withdraws caller collateral credits back to wallet collateral.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        _withdrawCollateral(msg.sender, amount);
    }

    /// @notice Withdraws caller outcome-token credits to wallet.
    function withdrawOutcomeToken(address token, uint256 amount) external nonReentrant {
        _withdrawOutcomeToken(msg.sender, token, amount);
    }

    /// @notice Mints complete sets in an allowlisted market using caller collateral credits.
    function mintCompleteSets(address market, uint256 amount) external nonReentrant {
        _mintCompleteSets(msg.sender, market, amount);
    }

    /// @notice Redeems complete sets for collateral in an allowlisted market.
    function redeemCompleteSets(address market, uint256 amount) external nonReentrant {
        _redeemCompleteSets(msg.sender, market, amount);
    }

    /// @notice Redeems winning outcome tokens after market resolution.
    function redeem(address market, uint256 amount) external nonReentrant {
        _redeem(msg.sender, market, amount);
    }

    /// @notice Swaps YES token credits for NO token credits through the market AMM.
    function swapYesForNo(address market, uint256 yesIn, uint256 minNoOut) external nonReentrant {
        _swapYesForNo(msg.sender, market, yesIn, minNoOut);
    }

    /// @notice Swaps NO token credits for YES token credits through the market AMM.
    function swapNoForYes(address market, uint256 noIn, uint256 minYesOut) external nonReentrant {
        _swapNoForYes(msg.sender, market, noIn, minYesOut);
    }

    /// @notice Adds liquidity using caller YES/NO credits and credits LP shares internally.
    function addLiquidity(address market, uint256 yesAmount, uint256 noAmount, uint256 minShares) external nonReentrant {
        _addLiquidity(msg.sender, market, yesAmount, noAmount, minShares);
    }

    /// @notice Removes liquidity from internal LP shares and credits resulting YES/NO balances.
    function removeLiquidity(address market, uint256 shares, uint256 minYesOut, uint256 minNoOut) external nonReentrant {
        _removeLiquidity(msg.sender, market, shares, minYesOut, minNoOut);
    }

    /// @dev Pulls collateral from payer and credits beneficiary in router accounting.
    function _depositCollateral(address payer, address beneficiary, uint256 amount) internal {
        collateralToken.safeTransferFrom(payer, address(this), amount);
        collateralCredits[beneficiary] += amount;
        totalCollateralCredits += amount;
        emit Deposited(beneficiary, amount);
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
    function _withdrawOutcomeToken(address user, address token, uint256 amount) internal {
        uint256 bal = tokenCredits[user][token];
        if (bal < amount) revert Router__InsufficientBalance();
        tokenCredits[user][token] = bal - amount;
        IERC20(token).safeTransfer(user, amount);
        emit OutcomeWithdrawn(user, token, amount);
    }

    /// @dev Verifies enough untracked collateral exists to issue new credits safely.
    function _creditFromUntrackedCollateral(address user, uint256 amount) internal view {
        if (user == address(0)) revert Router__ZeroAddress();
        if (amount == 0) revert Router__InvalidAmount();

        uint256 balance = collateralToken.balanceOf(address(this));
        uint256 credited = totalCollateralCredits;
        uint256 untracked = balance > credited ? balance - credited : 0;
        if (untracked < amount) revert Router__InsufficientUntrackedCollateral();
    }

    /// @dev Credits user collateral from off-chain fiat settlement funds.
    function _creditCollateralFromFiat(address user, uint256 amount) internal {
        _creditFromUntrackedCollateral(user, amount);
        collateralCredits[user] += amount;
        totalCollateralCredits += amount;
        emit CollateralCreditedFromFiat(user, amount);
    }

    /// @dev Credits user collateral from ETH deposit flow with replay protection by depositId.
    function _creditCollateralFromEth(address user, uint256 amount, bytes32 depositId) internal {
        if (depositId == bytes32(0)) revert Router__InvalidDepositId();
        if (processedEthDeposits[depositId]) revert Router__EthDepositAlreadyProcessed();
        _creditFromUntrackedCollateral(user, amount);
        processedEthDeposits[depositId] = true;
        collateralCredits[user] += amount;
        totalCollateralCredits += amount;
        emit CollateralCreditedFromEth(user, amount, depositId);
    }

    /// @dev Executes market mint flow, moving collateral credits into YES/NO token credits.
    function _mintCompleteSets(address user, address market, uint256 amount) internal {
        _validateMarket(market);
        _ensureCollateralMatch(market);

        uint256 exposure = userRiskExposure[user];
        if (!isRiskExempt[user] && exposure + amount > MarketConstants.MAX_RISK_EXPOSURE) {
            revert Router__RiskExposureExceeded();
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

        userRiskExposure[user] = exposure + amount;
        tokenCredits[user][yes] += yesDelta;
        tokenCredits[user][no] += noDelta;

        emit CompleteSetsMinted(user, market, amount, yesDelta, noDelta);
    }

    /// @dev Executes complete-set redemption flow, returning collateral credits to user.
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

    /// @dev Swaps internal YES balance into NO balance through market swap.
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

    /// @dev Swaps internal NO balance into YES balance through market swap.
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

    /// @dev Adds liquidity using internal balances and credits resulting LP shares.
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

    /// @dev Removes liquidity from internal LP shares and credits withdrawn YES/NO balances.
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

    /// @dev Dispatches receiver reports by action hash into router operations.
    /// Report shape is `(string actionType, bytes payload)`.
    function _processReport(bytes calldata report) internal override nonReentrant {
        (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));

        if (actionTypeHash == HASHED_DEPOSIT_FOR) {
            (address user, uint256 amount) = abi.decode(payload, (address, uint256));
            _depositCollateral(user, user, amount);
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
        } else if (actionTypeHash == HASHED_CREDIT_FROM_FIAT) {
            (address user, uint256 amount) = abi.decode(payload, (address, uint256));
            _creditCollateralFromFiat(user, amount);
        } else if (actionTypeHash == HASHED_CREDIT_FROM_ETH) {
            (address user, uint256 amount, bytes32 depositId) = abi.decode(payload, (address, uint256, bytes32));
            _creditCollateralFromEth(user, amount, depositId);
        } else if (actionTypeHash == HASHED_REDEEM_WINNINGS) {
            (address user, address market, uint256 amount) = abi.decode(payload, (address, address, uint256));
            _redeem(user, market, amount);
        } else {
            revert Router__ActionNotRecognized();
        }
    }
}
