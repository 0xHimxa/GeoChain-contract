export const MarketFactoryAbi =[
        {
            "type": "constructor",
            "inputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "UPGRADE_INTERFACE_VERSION",
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
            "name": "activeMarkets",
            "inputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
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
            "name": "addLiquidityToFactory",
            "inputs": [],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "arbitrateUnsafeMarket",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "maxSpendCollateral",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "minDeviationImprovementBps",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "broadcastCanonicalPrice",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "internalType": "uint256"
                },
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
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "broadcastResolution",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "outcome",
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
            "name": "ccipFeeToken",
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
            "name": "ccipNonce",
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
            "name": "ccipReceive",
            "inputs": [
                {
                    "name": "any2EvmMessage",
                    "type": "tuple",
                    "internalType": "struct Client.Any2EVMMessage",
                    "components": [
                        {
                            "name": "messageId",
                            "type": "bytes32",
                            "internalType": "bytes32"
                        },
                        {
                            "name": "sourceChainSelector",
                            "type": "uint64",
                            "internalType": "uint64"
                        },
                        {
                            "name": "sender",
                            "type": "bytes",
                            "internalType": "bytes"
                        },
                        {
                            "name": "data",
                            "type": "bytes",
                            "internalType": "bytes"
                        },
                        {
                            "name": "destTokenAmounts",
                            "type": "tuple[]",
                            "internalType": "struct Client.EVMTokenAmount[]",
                            "components": [
                                {
                                    "name": "token",
                                    "type": "address",
                                    "internalType": "address"
                                },
                                {
                                    "name": "amount",
                                    "type": "uint256",
                                    "internalType": "uint256"
                                }
                            ]
                        }
                    ]
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "ccipRouter",
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
            "name": "collateral",
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
            "name": "createMarket",
            "inputs": [
                {
                    "name": "question",
                    "type": "string",
                    "internalType": "string"
                },
                {
                    "name": "closeTime",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "resolutionTime",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "initialLiquidity",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [
                {
                    "name": "market",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "stateMutability": "nonpayable"
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
            "name": "getMarketFactoryCollateralBalance",
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
            "name": "getSpokeSelectors",
            "inputs": [],
            "outputs": [
                {
                    "name": "selectors",
                    "type": "uint64[]",
                    "internalType": "uint64[]"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "initialize",
            "inputs": [
                {
                    "name": "_collateral",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_forwarder",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_marketDeployer",
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
            "name": "isHubFactory",
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
            "name": "isSupportedChainSelector",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "internalType": "uint64"
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
            "name": "isVerified",
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
            "name": "marketById",
            "inputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
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
            "name": "marketCount",
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
            "name": "marketIdByAddress",
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
            "name": "marketToIndex",
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
            "name": "onHubMarketResolved",
            "inputs": [
                {
                    "name": "outcome",
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
            "name": "processedCcipMessages",
            "inputs": [
                {
                    "name": "",
                    "type": "bytes32",
                    "internalType": "bytes32"
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
            "name": "proxiableUUID",
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
            "name": "removeResolvedMarket",
            "inputs": [
                {
                    "name": "market",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "removeTrustedRemote",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "internalType": "uint64"
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
            "name": "resolutionNonceByMarketId",
            "inputs": [
                {
                    "name": "",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
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
            "name": "setCcipConfig",
            "inputs": [
                {
                    "name": "_ccipRouter",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_ccipFeeToken",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "_isHubFactory",
                    "type": "bool",
                    "internalType": "bool"
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
            "name": "setMarketDeployer",
            "inputs": [
                {
                    "name": "_marketDeployer",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setMarketIdMapping",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "market",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setSupportedChainSelector",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "internalType": "uint64"
                },
                {
                    "name": "isSupported",
                    "type": "bool",
                    "internalType": "bool"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "function",
            "name": "setTrustedRemote",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "internalType": "uint64"
                },
                {
                    "name": "remoteFactory",
                    "type": "address",
                    "internalType": "address"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
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
            "name": "trustedRemoteBySelector",
            "inputs": [
                {
                    "name": "",
                    "type": "uint64",
                    "internalType": "uint64"
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "bytes",
                    "internalType": "bytes"
                }
            ],
            "stateMutability": "view"
        },
        {
            "type": "function",
            "name": "upgradeToAndCall",
            "inputs": [
                {
                    "name": "newImplementation",
                    "type": "address",
                    "internalType": "address"
                },
                {
                    "name": "data",
                    "type": "bytes",
                    "internalType": "bytes"
                }
            ],
            "outputs": [],
            "stateMutability": "payable"
        },
        {
            "type": "function",
            "name": "withdrawCollateralFromEvents",
            "inputs": [
                {
                    "name": "share",
                    "type": "uint256",
                    "internalType": "uint256"
                },
                {
                    "name": "_marketId",
                    "type": "uint256",
                    "internalType": "uint256"
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "event",
            "name": "CanonicalPriceMessageReceived",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "indexed": true,
                    "internalType": "uint256"
                },
                {
                    "name": "yesPriceE6",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "noPriceE6",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "nonce",
                    "type": "uint64",
                    "indexed": false,
                    "internalType": "uint64"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "CcipConfigUpdated",
            "inputs": [
                {
                    "name": "router",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "feeToken",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "isHubFactory",
                    "type": "bool",
                    "indexed": true,
                    "internalType": "bool"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "CcipMessageSent",
            "inputs": [
                {
                    "name": "messageId",
                    "type": "bytes32",
                    "indexed": true,
                    "internalType": "bytes32"
                },
                {
                    "name": "destinationChainSelector",
                    "type": "uint64",
                    "indexed": true,
                    "internalType": "uint64"
                },
                {
                    "name": "messageType",
                    "type": "uint8",
                    "indexed": true,
                    "internalType": "uint8"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "ChainSelectorSupportUpdated",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "indexed": true,
                    "internalType": "uint64"
                },
                {
                    "name": "isSupported",
                    "type": "bool",
                    "indexed": true,
                    "internalType": "bool"
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
            "name": "MarketCreated",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "indexed": true,
                    "internalType": "uint256"
                },
                {
                    "name": "market",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "initialLiquidity",
                    "type": "uint256",
                    "indexed": true,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "MarketFactory__LiquidityAdded",
            "inputs": [
                {
                    "name": "amount",
                    "type": "uint256",
                    "indexed": true,
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
            "name": "ResolutionMessageReceived",
            "inputs": [
                {
                    "name": "marketId",
                    "type": "uint256",
                    "indexed": true,
                    "internalType": "uint256"
                },
                {
                    "name": "outcome",
                    "type": "uint8",
                    "indexed": true,
                    "internalType": "enum Resolution"
                },
                {
                    "name": "nonce",
                    "type": "uint64",
                    "indexed": false,
                    "internalType": "uint64"
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
            "name": "TrustedRemoteRemoved",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "indexed": true,
                    "internalType": "uint64"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "TrustedRemoteUpdated",
            "inputs": [
                {
                    "name": "chainSelector",
                    "type": "uint64",
                    "indexed": true,
                    "internalType": "uint64"
                },
                {
                    "name": "remoteFactory",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "UnsafeArbitrageExecuted",
            "inputs": [
                {
                    "name": "market",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                },
                {
                    "name": "yesForNo",
                    "type": "bool",
                    "indexed": true,
                    "internalType": "bool"
                },
                {
                    "name": "collateralSpent",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "deviationBeforeBps",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                },
                {
                    "name": "deviationAfterBps",
                    "type": "uint256",
                    "indexed": false,
                    "internalType": "uint256"
                }
            ],
            "anonymous": false
        },
        {
            "type": "event",
            "name": "Upgraded",
            "inputs": [
                {
                    "name": "implementation",
                    "type": "address",
                    "indexed": true,
                    "internalType": "address"
                }
            ],
            "anonymous": false
        },
        {
            "type": "error",
            "name": "AddressEmptyCode",
            "inputs": [
                {
                    "name": "target",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "ERC1967InvalidImplementation",
            "inputs": [
                {
                    "name": "implementation",
                    "type": "address",
                    "internalType": "address"
                }
            ]
        },
        {
            "type": "error",
            "name": "ERC1967NonPayable",
            "inputs": []
        },
        {
            "type": "error",
            "name": "FailedCall",
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
            "name": "MarketFactory__ActionNotRecognized",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ArbInsufficientImprovement",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ArbNoDirection",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ArbNotUnsafe",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ArbZeroAmount",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__CcipFeeTokenNotSet",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__CcipRouterNotSet",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ChainSelectorCantbezero",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ChainSelectornNotSupported",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__InvalidRemoteSender",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__InvalidResolutionOutcome",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__MarketNotFound",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__MessageAlreadyProcessed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__NotHubFactory",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__OnlyRegisteredMarket",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__SourceChainNotAllowed",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__StaleResolutionNonce",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__UnknownSyncMessageType",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ZeroAddress",
            "inputs": []
        },
        {
            "type": "error",
            "name": "MarketFactory__ZeroLiquidity",
            "inputs": []
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
            "name": "PredictionMarket__CloseTimeGreaterThanResolutionTime",
            "inputs": []
        },
        {
            "type": "error",
            "name": "PredictionMarket__InvalidArguments_PassedInConstructor",
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
            "name": "UUPSUnauthorizedCallContext",
            "inputs": []
        },
        {
            "type": "error",
            "name": "UUPSUnsupportedProxiableUUID",
            "inputs": [
                {
                    "name": "slot",
                    "type": "bytes32",
                    "internalType": "bytes32"
                }
            ]
        },
        {
            "type": "error",
            "name": "WorkflowNameRequiresAuthorValidation",
            "inputs": []
        }
    ]