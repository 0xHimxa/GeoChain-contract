export const PredictionMarketAbi =   [
        {
            "type": "constructor",
            "inputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "addLiquidity",
            "inputs": [
                {
                    "name": "yesAmount",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "noAmount",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minShares",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "canonicalNoPriceE6",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "canonicalPriceNonce",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint64",
                    "internalType": "uint64"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "canonicalPriceValidUntil",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "canonicalYesPriceE6",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "checkResolutionTime",
            "inputs": [],
            "outputs": [
                {
                    "name": "resolveReady",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "closeTime",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "crossChainController",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getDeviationStatus",
            "inputs": [],
            "outputs": [
                {
                    "name": "band",
                    "type": "uint8",
                    "internalType": "enum PredictionMarket.DeviationBand"
                },
                {
                    "name": "deviationBps",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "effectiveFeeBps",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "maxOutBps",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "allowYesForNo",
                    "type": "bool",
                    "internalType": "bool"
                },
                {
                    "name": "allowNoForYes",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getExpectedAuthor",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getExpectedWorkflowId",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "bytes32",
                    "internalType": "bytes32"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getExpectedWorkflowName",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "bytes10",
                    "internalType": "bytes10"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getForwarderAddress",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getNoForYesQuote",
            "inputs": [
                {
                    "name": "noIn",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [
                {
                    "name": "netOut",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "fee",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getNoPriceProbability",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getYesForNoQuote",
            "inputs": [
                {
                    "name": "yesIn",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [
                {
                    "name": "netOut",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "fee",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "getYesPriceProbability",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "hardDeviationBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "i_collateral",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "contract IERC20"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "initialize",
            "inputs": [
                {
                    "name": "_question",
                    "type": "string",
                    "internalType": "string"
                },
                {
                    "name": "_collateral",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_closeTime",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "_resolutionTime",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "_marketfactory",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_forwarderAddress",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_initialOwner",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "isRiskExempt",
            "inputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "lpShares",
            "inputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "manualResolveMarket",
            "inputs": [
                {
                    "name": "_outcome",
                    "type": "uint8",
                    "internalType": "enum Resolution"
                },
                {
                    "name": "proofUrl",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "mintCompleteSets",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "noReserve",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "noToken",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "contract OutcomeToken"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "onReport",
            "inputs": [
                {
                    "name": "metadata",
                    "type": "bytes",
                    "internalType": "bytes"
                },
                {
                    "name": "report",
                    "type": "bytes",
                    "internalType": "bytes"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "owner",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "pause",
            "inputs": [],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "paused",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "protocolCollateralFees",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "redeem",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "redeemCompleteSets",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "removeLiquidity",
            "inputs": [
                {
                    "name": "shares",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minYesOut",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minNoOut",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "removeLiquidityAndRedeemCollateral",
            "inputs": [
                {
                    "name": "shares",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minCollateralOut",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "renounceOwnership",
            "inputs": [],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "resolution",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint8",
                    "internalType": "enum Resolution"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "resolutionTime",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "resolve",
            "inputs": [
                {
                    "name": "_outcome",
                    "type": "uint8",
                    "internalType": "enum Resolution"
                },
                {
                    "name": "proofUrl",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "resolveFromHub",
            "inputs": [
                {
                    "name": "_outcome",
                    "type": "uint8",
                    "internalType": "enum Resolution"
                },
                {
                    "name": "proofUrl",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "s_Proof_Url",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "s_question",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "seedLiquidity",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "seeded",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "setCrossChainController",
            "inputs": [
                {
                    "name": "controller",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setDeviationPolicy",
            "inputs": [
                {
                    "name": "_softDeviationBps",
                    "type": "uint16",
                    "internalType": "uint16"
                },
                {
                    "name": "_stressDeviationBps",
                    "type": "uint16",
                    "internalType": "uint16"
                },
                {
                    "name": "_hardDeviationBps",
                    "type": "uint16",
                    "internalType": "uint16"
                },
                {
                    "name": "_stressExtraFeeBps",
                    "type": "uint16",
                    "internalType": "uint16"
                },
                {
                    "name": "_stressMaxOutBps",
                    "type": "uint16",
                    "internalType": "uint16"
                },
                {
                    "name": "_unsafeMaxOutBps",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setExpectedAuthor",
            "inputs": [
                {
                    "name": "_author",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setExpectedWorkflowId",
            "inputs": [
                {
                    "name": "_id",
                    "type": "bytes32",
                    "internalType": "bytes32"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setExpectedWorkflowName",
            "inputs": [
                {
                    "name": "_name",
                    "type": "string",
                    "internalType": "string"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setForwarderAddress",
            "inputs": [
                {
                    "name": "_forwarder",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setRiskExempt",
            "inputs": [
                {
                    "name": "account",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "exempt",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "softDeviationBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "state",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint8",
                    "internalType": "enum State"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "stressDeviationBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "stressExtraFeeBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "stressMaxOutBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "supportsInterface",
            "inputs": [
                {
                    "name": "interfaceId",
                    "type": "bytes4",
                    "internalType": "bytes4"
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "stateMutability": "pure"
        },
        {
            "type": "function",
            "name": "swapNoForYes",
            "inputs": [
                {
                    "name": "noIn",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minYesOut",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "swapYesForNo",
            "inputs": [
                {
                    "name": "yesIn",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minNoOut",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "syncCanonicalPriceFromHub",
            "inputs": [
                {
                    "name": "yesPriceE6",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "noPriceE6",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "validUntil",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "nonce",
                    "type": "uint64",
                    "internalType": "uint64"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "totalShares",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "transferOwnership",
            "inputs": [
                {
                    "name": "newOwner",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "transferShares",
            "inputs": [
                {
                    "name": "to",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "shares",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "unpause",
            "inputs": [],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "unsafeMaxOutBps",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint16",
                    "internalType": "uint16"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "userRiskExposure",
            "inputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "withdrawLiquidityCollateral",
            "inputs": [
                {
                    "name": "shares",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "withdrawProtocolFees",
            "inputs": [],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "yesReserve",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "yesToken",
            "inputs": [],
            "outputs": [
                {
                    "name": "",
                    "type": "address",
                    "internalType": "contract OutcomeToken"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "event",
            "name": "CompleteSetsMinted",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "CompleteSetsRedeemed",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "DeviationPolicyUpdated",
            "inputs": [
                {
                    "name": "softDeviationBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                },
                {
                    "name": "stressDeviationBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                },
                {
                    "name": "hardDeviationBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                },
                {
                    "name": "stressExtraFeeBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                },
                {
                    "name": "stressMaxOutBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                },
                {
                    "name": "unsafeMaxOutBps",
                    "type": "uint16",
                    "indexed": false,
                    "internalType": "uint16"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "ExpectedAuthorUpdated",
            "inputs": [
                {
                    "name": "previousAuthor",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "newAuthor",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "ExpectedWorkflowIdUpdated",
            "inputs": [
                {
                    "name": "previousId",
                    "type": "bytes32",
                    "indexed": true,
                    "internalType": "bytes32"
                },
                {
                    "name": "newId",
                    "type": "bytes32",
                    "indexed": true,
                    "internalType": "bytes32"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "ExpectedWorkflowNameUpdated",
            "inputs": [
                {
                    "name": "previousName",
                    "type": "bytes10",
                    "indexed": true,
                    "internalType": "bytes10"
                },
                {
                    "name": "newName",
                    "type": "bytes10",
                    "indexed": true,
                    "internalType": "bytes10"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "ForwarderAddressUpdated",
            "inputs": [
                {
                    "name": "previousForwarder",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "newForwarder",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Initialized",
            "inputs": [
                {
                    "name": "version",
                    "type": "uint64",
                    "indexed": false,
                    "internalType": "uint64"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "IsUnderManualReview",
            "inputs": [
                {
                    "name": "outcome",
                    "type": "uint8",
                    "indexed": true,
                    "internalType": "enum Resolution"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "LiquidityAdded",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "yesAmount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "noAmount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "shares",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "LiquidityRemoved",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "yesAmount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "noAmount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "shares",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "LiquiditySeeded",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "OwnershipTransferred",
            "inputs": [
                {
                    "name": "previousOwner",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "newOwner",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Paused",
            "inputs": [
                {
                    "name": "account",
                    "type": "address",
                    "indexed": false,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Redeemed",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Resolved",
            "inputs": [
                {
                    "name": "outcome",
                    "type": "uint8",
                    "indexed": false,
                    "internalType": "enum Resolution"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "SecurityWarning",
            "inputs": [
                {
                    "name": "message",
                    "type": "string",
                    "indexed": false,
                    "internalType": "string"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "SharesTransferred",
            "inputs": [
                {
                    "name": "from",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "to",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "shares",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Trade",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "yesForNo",
                    "type": "bool",
                    "indexed": false,
                    "internalType": "bool"
                },
                {
                    "name": "amountIn",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "amountOut",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Unpaused",
            "inputs": [
                {
                    "name": "account",
                    "type": "address",
                    "indexed": false,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "WithDrawnLiquidity",
            "inputs": [
                {
                    "name": "user",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "shares",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "error",
            "name": "EnforcedPause",
            "inputs": []
        },
        {
            "type": "error",
            "name": "ExpectedPause",
            "inputs": []
        },
        {
            "type": "error",
            "name": "InvalidAuthor",
            "inputs": [
                {
                    "name": "received",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "expected",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "InvalidForwarderAddress",
            "inputs": []
        },
        {
            "type": "error",
            "name": "InvalidInitialization",
            "inputs": []
        },
        {
            "type": "error",
            "name": "InvalidSender",
            "inputs": [
                {
                    "name": "sender",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "expected",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "InvalidWorkflowId",
            "inputs": [
                {
                    "name": "received",
                    "type": "bytes32",
                    "internalType": "bytes32"
                },
                {
                    "name": "expected",
                    "type": "bytes32",
                    "internalType": "bytes32"
                }
            ]
        },
        {
            "type": "error",
            "name": "InvalidWorkflowName",
            "inputs": [
                {
                    "name": "received",
                    "type": "bytes10",
                    "internalType": "bytes10"
                },
                {
                    "name": "expected",
                    "type": "bytes10",
                    "internalType": "bytes10"
                }
            ]
        },
        {
            "type": "error",
            "name": "NotInitializing",
            "inputs": []
        },
        {
            "type": "error",
            "name": "OwnableInvalidOwner",
            "inputs": [
                {
                    "name": "owner",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "OwnableUnauthorizedAccount",
            "inputs": [
                {
                    "name": "account",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "PredictionMarket__AddLiquidity_InsuffientTokenBalance",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AddLiquidity_YesAndNoCantBeZero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AlreadyResolved",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AmountCantBeZero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AmountLessThanMinAllwed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__AmountLessThanMinSwapAllwed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__CanonicalPriceDeviationTooHigh",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__CanonicalPriceStale",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__CloseTimeGreaterThanResolutionTime",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__CrossChainControllerCantBeZero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__DeviationPolicyInvalid",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__FundingInitailAountGreaterThanAmountSent",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InitailConstantLiquidityAlreadySet",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InitailConstantLiquidityNotSetYet",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InvalidArguments_PassedInConstructor",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InvalidCanonicalPrice",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InvalidFinalOutcome",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InvalidReport",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__IsPaused",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__IsUnderManualReview",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__Isclosed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__LocalResolutionDisabled",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__ManualReviewNeeded",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__MarketFactoryAddressCantBeZero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__MarketNotClosed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__MarketNotInReview",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__MintCompleteSets_InsuffientTokenBalance",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__MintingCompleteset__AmountLessThanMinimu",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__NotOwner_Or_CrossChainController",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__NotResolved",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__OnlyCrossChainController",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__ProofUrlCantBeEmpty",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__RedeemCompletesetLessThanMinAllowed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__ResolveTimeNotReached",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__RiskExposureExceeded",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__RiskExposureExemptZeroAddress",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__StaleSyncMessage",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__StateNeedToResolvedToWithdrawLiquidity",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__SwapNoFoYes_NoExeedBalannce",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__SwapYesFoNo_YesExeedBalannce",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__SwapingExceedSlippage",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__TradeDirectionNotAllowedInUnsafeBand",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__TradeSizeExceedsBandLimit",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__TransferShares_CantbeSendtoZeroAddress",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__TransferShares_InsufficientShares",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__WithDrawLiquidity_Insufficientfee",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__WithDrawLiquidity_SlippageExceeded",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__redeemCompleteSets_InsuffientTokenBalance",
            "inputs": []
        },
        {
            "type": "error",
            "name": "ReentrancyGuardReentrantCall",
            "inputs": []
        },
        {
            "type": "error",
            "name": "SafeERC20FailedOperation",
            "inputs": [
                {
                    "name": "token",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "WorkflowNameRequiresAuthorValidation",
            "inputs": []
        }
    ]