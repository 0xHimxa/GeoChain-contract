// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketFactory} from "../src/marketFactory/MarketFactory.sol";
import {OutcomeToken} from "../src/token/OutcomeToken.sol";
import {MarketDeployer} from "../src/marketFactory/event-deployer/MarketDeployer.sol";
import {PredictionMarket} from "../src/predictionMarket/PredictionMarket.sol";

/**
 * @title DeployMarketFactory
 * @notice Foundry deployment script for the full MarketFactory system on a local Anvil chain
 * @dev Deploys: mock USDC collateral → MarketDeployer → MarketFactory (UUPS proxy)
 *      Then wires them together and seeds the factory with testnet USDC liquidity.
 *      Uses Anvil's default accounts (index 0 = owner, index 1 = forwarder placeholder).
 */
contract DeployMarketFactory is Script {
       
    
    function run() external returns (address proxyAddress, address implementationAddress, address collateralAddress) {
        OutcomeToken collateral;

        // Anvil default account #1 used as workflow forwarder placeholder in tests.
        address forwarder = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;


        // Anvil default account #0 expected by test suite as factory owner/admin.
        address initialOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

       
     
        vm.startBroadcast(initialOwner);

        // 1. Deploy a mock USDC token (OutcomeToken reused as a mintable ERC20) owned by initialOwner
        collateral = new OutcomeToken("USDC", "USDC", initialOwner);

        // 2. Deploy a single PredictionMarket implementation used for clones
        PredictionMarket marketImplementation = new PredictionMarket();

        // 3. Deploy the MarketDeployer helper that clones from marketImplementation
        MarketDeployer marketDeployer = new MarketDeployer(address(marketImplementation),initialOwner);

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

        // 7. Transfer collateral token ownership to the factory proxy so it can mint testnet USDC
        collateral.transferOwnership(proxyAddress);

        // 8. Fund the factory with 100,000 testnet USDC (minted via addLiquidityToFactory)
        MarketFactory(proxyAddress).addLiquidityToFactory();
 marketDeployer.setNewOwner(proxyAddress);
        vm.stopBroadcast();

        // Log deployed addresses for verification
        collateralAddress = address(collateral);
        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
        console2.log("MarketFactory collateral Balance:", collateral.balanceOf(proxyAddress));
    }
}




