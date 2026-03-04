// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketFactory} from "../src/marketFactory/MarketFactory.sol";
import {OutcomeToken} from "../src/token/OutcomeToken.sol";
import {MarketDeployer} from "../src/marketFactory/event-deployer/MarketDeployer.sol";
import {PredictionMarket} from "../src/predictionMarket/PredictionMarket.sol";
import {PredictionMarketBridge} from "../src/Bridge/PredictionMarketBridge.sol";
import {PredictionMarketRouterVault} from "src/router/PredictionMarketRouterVault.sol";

/**
 * @title DeployMarketFactory
 * @notice Foundry deployment script for the full MarketFactory system on a local Anvil chain
 * @dev Deploys: mock USDC collateral → MarketDeployer → MarketFactory (UUPS proxy)
 *      Then wires them together and seeds the factory with testnet USDC liquidity.
 *      Uses Anvil's default accounts (index 0 = owner, index 1 = forwarder placeholder).
 */
contract DeployMarketFactory is Script {
    address router = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address link = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;
    OutcomeToken collateral;

    function run() external returns (address proxyAddress, address implementationAddress, address collateralAddress) {
        // Anvil default account #1 used as workflow forwarder placeholder in tests.
        address forwarder = 0xD41263567DdfeAd91504199b8c6c87371e83ca5d;

        // Anvil default account #0 expected by test suite as factory owner/admin.
        address initialOwner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;

        vm.startBroadcast(initialOwner);

        // 1. Deploy a mock USDC token (OutcomeToken reused as a mintable ERC20) owned by initialOwner
        collateral = new OutcomeToken("USDC", "USDC", initialOwner);

        // 2. Deploy a single PredictionMarket implementation used for clones
        PredictionMarket marketImplementation = new PredictionMarket();

        // 3. Deploy the MarketDeployer helper that clones from marketImplementation
        MarketDeployer marketDeployer = new MarketDeployer(address(marketImplementation), initialOwner);

        // 4. Deploy the MarketFactory implementation (logic contract, not used directly)
        MarketFactory implementation = new MarketFactory();
        implementationAddress = address(implementation);

        //Mint collateral to self

        collateral.mint(initialOwner, 1000000e6);

        // 5. Encode the initialize() call to pass as ERC1967Proxy constructor data
        bytes memory initData = abi.encodeCall(
            MarketFactory.initialize, (address(collateral), forwarder, address(marketDeployer), initialOwner)
        );

        // 6. Deploy the UUPS proxy pointing to the MarketFactory implementation
        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proxyAddress = address(proxy);

        // deploy PredictionMarketBridge
        PredictionMarketBridge bridge = new PredictionMarketBridge(initialOwner, address(collateral));
        bridge.setCcipConfig(router, link);
        bridge.setMarketFactory(proxyAddress);
        bridge.setSupportedChainSelector(10344971235874465080, true);

        // 7. Transfer collateral token ownership to the factory proxy so it can mint testnet USDC
        collateral.transferOwnership(proxyAddress);

        // 8. Fund the factory with 100,000 testnet USDC (minted via addLiquidityToFactory)
        MarketFactory(proxyAddress).addLiquidityToFactory();
        MarketFactory(proxyAddress).addLiquidityToFactory();
        MarketFactory(proxyAddress).setCcipConfig(router, link, true);
        MarketFactory(proxyAddress).setPredictionMarketBridge(address(bridge));

        marketDeployer.setNewOwner(proxyAddress);

        // router deployment
        PredictionMarketRouterVault routerImpl = new PredictionMarketRouterVault();
        bytes memory routerInitData = abi.encodeCall(
            PredictionMarketRouterVault.initialize, (address(collateral), forwarder, initialOwner, proxyAddress)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInitData);
        PredictionMarketRouterVault routerVal = PredictionMarketRouterVault(payable(address(routerProxy)));
        MarketFactory(proxyAddress).setPredictionMarketRouter(address(routerVal));
        console.log(address(routerVal));
        vm.stopBroadcast();

        // Log deployed addresses for verification
        collateralAddress = address(collateral);
        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
        console2.log("MarketFactory collateral Balance:", collateral.balanceOf(proxyAddress));
        console2.log("PredictionMarketBrige:", address(bridge));
    }
}

contract BaseDeployMarketFactory is Script {
    address router = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address link = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    OutcomeToken collateral;

    function run() external returns (address proxyAddress, address implementationAddress, address collateralAddress) {
        // Anvil default account #1 used as workflow forwarder placeholder in tests.
        address forwarder = 0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5;

        // Anvil default account #0 expected by test suite as factory owner/admin.
        address initialOwner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;

        vm.startBroadcast(initialOwner);

        // 1. Deploy a mock USDC token (OutcomeToken reused as a mintable ERC20) owned by initialOwner
        collateral = new OutcomeToken("USDC", "USDC", initialOwner);

        // 2. Deploy a single PredictionMarket implementation used for clones
        PredictionMarket marketImplementation = new PredictionMarket();

        // 3. Deploy the MarketDeployer helper that clones from marketImplementation
        MarketDeployer marketDeployer = new MarketDeployer(address(marketImplementation), initialOwner);

        // 4. Deploy the MarketFactory implementation (logic contract, not used directly)
        MarketFactory implementation = new MarketFactory();
        implementationAddress = address(implementation);

        //Mint collateral to self

        collateral.mint(initialOwner, 1000000e6);

        // 5. Encode the initialize() call to pass as ERC1967Proxy constructor data
        bytes memory initData = abi.encodeCall(
            MarketFactory.initialize, (address(collateral), forwarder, address(marketDeployer), initialOwner)
        );

        // 6. Deploy the UUPS proxy pointing to the MarketFactory implementation
        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proxyAddress = address(proxy);

        // deploy PredictionMarketBridge
        PredictionMarketBridge bridge = new PredictionMarketBridge(initialOwner, address(collateral));
        bridge.setCcipConfig(router, link);
        bridge.setMarketFactory(proxyAddress);
        bridge.setSupportedChainSelector(3478487238524512106, true);

        // 7. Transfer collateral token ownership to the factory proxy so it can mint testnet USDC
        collateral.transferOwnership(proxyAddress);

        // 8. Fund the factory with 100,000 testnet USDC (minted via addLiquidityToFactory)
        MarketFactory(proxyAddress).addLiquidityToFactory();
        MarketFactory(proxyAddress).addLiquidityToFactory();
        MarketFactory(proxyAddress).setCcipConfig(router, link, false);
        MarketFactory(proxyAddress).setPredictionMarketBridge(address(bridge));

        marketDeployer.setNewOwner(proxyAddress);

        // router deployment
        PredictionMarketRouterVault routerImpl = new PredictionMarketRouterVault();
        bytes memory routerInitData = abi.encodeCall(
            PredictionMarketRouterVault.initialize, (address(collateral), forwarder, initialOwner, proxyAddress)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInitData);
        PredictionMarketRouterVault routerVal = PredictionMarketRouterVault(payable(address(routerProxy)));
        MarketFactory(proxyAddress).setPredictionMarketRouter(address(routerVal));
        console.log(address(routerVal));
        vm.stopBroadcast();

        // Log deployed addresses for verification
        collateralAddress = address(collateral);
        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
        console2.log("MarketFactory collateral Balance:", collateral.balanceOf(proxyAddress));
        console2.log("PredictionMarketBrige:", address(bridge));
    }
}

contract DeployRouter is Script {
    address arbMarketFactory = 0x1dAf6Ecab082971aCF99E50B517cf297B51B6e5C;
    address baseMarketFactory = 0x73f6A1a5B211E39AcE6F6AF108d7c6e0F77e3B92;
    address arbCollateral = 0x52539038C1d1C88AA12438e3c13ADC6778B966Fc ;
    address baseCollateral = 0xB17Ede44C636887ce980D9359A176a088DC46c2f;
    address initialOwner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    address forwarder = 0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5;

    function run() external {
        vm.startBroadcast(initialOwner);
        PredictionMarketRouterVault routerImpl = new PredictionMarketRouterVault();
        bytes memory routerInitData = abi.encodeCall(
            PredictionMarketRouterVault.initialize, (baseCollateral, forwarder, initialOwner, baseMarketFactory)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInitData);
        PredictionMarketRouterVault routerVal = PredictionMarketRouterVault(payable(address(routerProxy)));
        MarketFactory(baseMarketFactory).setPredictionMarketRouter(address(routerVal));

        vm.stopBroadcast();
    }
}
