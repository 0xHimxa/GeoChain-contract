// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MarketFactory} from "src/upgrades/MarketFactory.sol";

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
        proxyAddress = 0x015a4e609ED01012ff4B9401a274BE84C89052E6;
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
