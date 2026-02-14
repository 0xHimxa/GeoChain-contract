// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketFactory} from "src/MarketFactory.sol";

contract DeployMarketFactory is Script {
    function run() external returns (address proxyAddress, address implementationAddress) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address collateral = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        vm.startBroadcast(deployerKey);

        MarketFactory implementation = new MarketFactory();
        implementationAddress = address(implementation);

        address initialOwner = vm.addr(deployerKey);
        bytes memory initData = abi.encodeCall(MarketFactory.initialize, (collateral, forwarder, initialOwner));

        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proxyAddress = address(proxy);

        vm.stopBroadcast();

        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
    }
}
