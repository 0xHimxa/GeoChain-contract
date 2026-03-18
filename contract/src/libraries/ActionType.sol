// SPDX-License-Identifier: MIT
pragma solidity 0.8.33


/// The library assumes reserves and token units share the same decimals.
library ActionTypeHashed {

// Action type hashes for off-chain CRE reports, used in PredictionMarketResolution.

    bytes32 internal constant HASHED_RESOLVE_MARKET =
        keccak256(abi.encodePacked("ResolveMarket"));
    bytes32 internal constant HASHED_FINALIZE_RESOLUTION_AFTER_DISPUTE_WINDOW =
        keccak256(abi.encodePacked("FinalizeResolutionAfterDisputeWindow"));
    bytes32 internal constant HASHED_ADJUDICATE_DISPUTED_RESOLUTION =
        keccak256(abi.encodePacked("AdjudicateDisputedResolution"));
    bytes32 internal constant HASHED_LMSR_BUY =
        keccak256(abi.encodePacked("LMSRBuy"));
    bytes32 internal constant HASHED_LMSR_SELL =
        keccak256(abi.encodePacked("LMSRSell"));



//Market factory and maintenance action type hashes for off-chain CRE reports, used in PredictionMarket.

            /// @dev Action hash for broadcast-price report.
    bytes32 internal hashed_BroadCastPrice;
    /// @dev Action hash for direct spoke canonical-price sync report.
    bytes32 internal hashed_SyncSpokeCanonicalPrice;
    /// @dev Action hash for broadcast-resolution report.
    bytes32 internal hashed_BroadCastResolution;
    /// @dev Action hash for create-market report.
    bytes32 internal hashed_CreateMarket;
    /// @dev Action hash for unsafe-price-correction report.
    bytes32 internal hashed_PriceCorrection;
    /// @dev Action hash for add-liquidity-to-factory report.
    bytes32 internal hashed_AddLiquidityToFactory;
    /// @dev Action hash for combined withdraw report.
    bytes32 internal hashed_WithCollatralAndFee;
    /// @dev Action hash for pending-withdraw processing report.
    bytes32 internal hashed_ProcessPendingWithdrawals;



        bytes32 internal constant HASHED_PRE_CLOSE_LMSR_SELL = keccak256(abi.encode("preCloseLmsrSell"));
    uint256 internal constant PRE_CLOSE_SELL_WINDOW = 2 minutes;




}