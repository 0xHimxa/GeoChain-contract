// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";




contract DeployMarketFactory is Script {
    function run() external returns (address proxyAddress, address implementationAddress, address collateralAddress) {
      //  uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        OutcomeToken collateral;
        // this are anvil top 2 address
        address forwarder =  0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address initialOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;


        vm.startBroadcast(initialOwner);
       collateral = new OutcomeToken("USDC", "USDC", initialOwner);

        MarketFactory implementation = new MarketFactory();
        implementationAddress = address(implementation);
        bytes memory initData = abi.encodeCall(MarketFactory.initialize, (address(collateral), forwarder, initialOwner));

        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proxyAddress = address(proxy);

 collateral.transferOwnership(proxyAddress);

        vm.stopBroadcast();
collateralAddress = address(collateral);
        console2.log("MarketFactory implementation:", implementationAddress);
        console2.log("MarketFactory proxy:", proxyAddress);
        console2.log("MarketFactory owner:", initialOwner);
    }
}
