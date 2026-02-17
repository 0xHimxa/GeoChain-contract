// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {MarketDeployer} from "src/MarketDeployer.sol";

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

        // Anvil default account #1 – used as the Chainlink CRE forwarder placeholder for local testing
        address forwarder = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

        // Anvil default account #0 – acts as the initial owner of all deployed contracts
        address initialOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

        vm.startBroadcast(initialOwner);

        // 1. Deploy a mock USDC token (OutcomeToken reused as a mintable ERC20) owned by initialOwner
        collateral = new OutcomeToken("USDC", "USDC", initialOwner);

        // 2. Deploy the MarketDeployer helper (holds PredictionMarket creation bytecode)
        MarketDeployer marketDeployer = new MarketDeployer(initialOwner);

        // 3. Deploy the MarketFactory implementation (logic contract, not used directly)
        MarketFactory implementation = new MarketFactory();
        implementationAddress = address(implementation);

        // 4. Encode the initialize() call to pass as ERC1967Proxy constructor data
        bytes memory initData = abi.encodeCall(
            MarketFactory.initialize, (address(collateral), forwarder, address(marketDeployer), initialOwner)
        );

        // 5. Deploy the UUPS proxy pointing to the MarketFactory implementation
        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proxyAddress = address(proxy);

        // 6. Bind the deployer to the factory proxy so it accepts deployPredictionMarket() calls
        marketDeployer.setFactory(proxyAddress);

        // 7. Transfer collateral token ownership to the factory proxy so it can mint testnet USDC
        collateral.transferOwnership(proxyAddress);

        // 8. Fund the factory with 100,000 testnet USDC (minted via addLiquidityToFactory)
        MarketFactory(proxyAddress).addLiquidityToFactory();

        vm.stopBroadcast();

        // Log deployed addresses for verification
        collateralAddress = address(collateral);
        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
        console2.log("MarketFactory collateral Balance:", collateral.balanceOf(proxyAddress));
    }
}
