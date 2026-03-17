// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketBridge} from "src/Bridge/PredictionMarketBridge.sol";
import {PredictionMarket} from "src/predictionMarket/PredictionMarket.sol";
import {MarketFactory} from "src/marketFactory/MarketFactory.sol";


contract BridgeToken  is Script {
   address collateralToken = 0x5b2b8BB2e7139925cdbe5FeFE73CfF45D215CD84 ;
    address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    
    address marketAddr = 0xA8735c76fA6E04f705204100FbE56582f0e420eD;
        //PredictionMarket market = PredictionMarket(marketAddr);
      address router = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;





address  marketFactory = 0x89D7F9aA690cDCB2265351FcA0fD260Ed0c7608E;


address arbMarketFactory = 0xA8735c76fA6E04f705204100FbE56582f0e420eD;


uint64 chainSelector = 10344971235874465080;
uint64 arbChainSelector = 3478487238524512106;
//base: selector, 10344971235874465080
  
    function run() external {
        vm.startBroadcast(trader);
        PredictionMarketBridge bridge =   PredictionMarketBridge(0xc90E272314115fe79B42741E439a8fD8A58a8aEF);
        bridge.setCcipConfig(router, link);
        bridge.setMarketFactory(marketFactory);
        bridge.setSupportedChainSelector(arbChainSelector, true);
        bridge.setMarketIdMapping(1,   0xFaea1b669e432CA0Ba77665a1b9B2B29aB5903DE);
       bridge.setMarketIdMapping(2,    0x7C8fB4FF245bcd9a504e8502315598A2d04fddAa);
       bridge.setTrustedRemote(chainSelector, 0x770B733050f07D93fa827ac82230c0eD9baB4A6c);
       MarketFactory(marketFactory).setPredictionMarketBridge(0x770B733050f07D93fa827ac82230c0eD9baB4A6c);




            


vm.stopBroadcast();
    }




}