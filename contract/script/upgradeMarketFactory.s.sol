// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MarketFactory} from "../src/marketFactory/MarketFactory.sol";

/**
 * @title UpgradeMarketFactory
 * @notice Foundry script to upgrade a MarketFactory UUPS proxy to a new implementation.
 * @dev Required env vars:
 *      - PRIVATE_KEY: owner key that can authorize upgrades
 *      - MARKET_FACTORY_PROXY: proxy address to upgrade
 *      - UPGRADE_CALLDATA: bytes calldata for post-upgrade initialization ("0x" if none)
 */
contract UpgradeMarketFactory is Script {
    function run() external returns (address proxyAddress, address newImplementationAddress) {
       
        address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
        proxyAddress = 0x02b0E40A0D3E6A0fb27aBBb5FA4f39B40e131bd3;
        bytes memory upgradeCallData = "";

        vm.startBroadcast(owner);

        MarketFactory newImplementation = new MarketFactory();
        newImplementationAddress = address(newImplementation);

        MarketFactory(payable(proxyAddress)).upgradeToAndCall(newImplementationAddress, upgradeCallData);

        vm.stopBroadcast();

        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("New implementation:", newImplementationAddress);
    }
}
