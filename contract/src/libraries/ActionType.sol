// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


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
 bytes32 internal constant hashed_BroadCastPrice = keccak256(abi.encode("broadCastPrice"));

  /// @dev Action hash for direct spoke canonical-price sync report.
        bytes32 internal constant hashed_SyncSpokeCanonicalPrice = keccak256(
            abi.encode("syncSpokeCanonicalPrice")
        );
         /// @dev Action hash for broadcast-resolution report.
        bytes32 internal constant hashed_BroadCastResolution = keccak256(
            abi.encode("broadCastResolution")
        );
         /// @dev Action hash for create-market report.
        bytes32 internal constant hashed_CreateMarket = keccak256(abi.encode("createMarket"));
         /// @dev Action hash for unsafe-price-correction report.
        bytes32 internal constant hashed_PriceCorrection = keccak256(abi.encode("priceCorrection"));
            /// @dev Action hash for add-liquidity-to-factory report.
        bytes32 internal constant hashed_AddLiquidityToFactory = keccak256(
            abi.encode("addLiquidityToFactory")
        );
            /// @dev Action hash for combined withdraw report.
        bytes32 internal constant hashed_WithCollatralAndFee = keccak256(
            abi.encode("WithCollatralAndFee")
        );
                /// @dev Action hash for pending-withdraw processing report.
        bytes32 internal constant hashed_ProcessPendingWithdrawals = keccak256(
            abi.encode("processPendingWithdrawals")
        );
         bytes32 internal constant mintCollateralToActionHash = keccak256(
            abi.encode("mintCollateralTo")
        );


        bytes32 internal constant HASHED_PRE_CLOSE_LMSR_SELL = keccak256(abi.encode("preCloseLmsrSell"));
 




}