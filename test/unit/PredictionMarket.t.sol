// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import{Test,console} from "forge-std/Test.sol";
import{MarketFactory} from "src/MarketFactory.sol";
import{OutcomeToken} from "src/OutcomeToken.sol";
import{DeployMarketFactory} from "script/deployMarketFactory.s.sol";
import{MarketErrors} from "src/libraries/MarketTypes.sol";

 
contract MarketFactoryTest is Test{



   event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        string question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 indexed initialLiquidity
    );










OutcomeToken collateral;
MarketFactory market;
 address forwarder =  0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address marketOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
uint256 initialFunding = 1000000e6;
uint256 initialLiquidity = 10000e6;

    function setUp()external{
DeployMarketFactory deployer = new DeployMarketFactory();
 (address proxyAddress,, address collateralAddress) = deployer.run();
  collateral = OutcomeToken(collateralAddress);
  market = MarketFactory(proxyAddress);






    }

function testCollateralAndForwarderAddress()external {

   address MarketCollateralAddress = address(market.collateral());
assertEq(address(collateral),MarketCollateralAddress);
assertEq(forwarder, market.getForwarderAddress());

}


function testCreateMarketRevertInvalidPram() external{

string memory question = "";
uint256 closeTime = 0;
uint256 resolutionTime = 0;

vm.startPrank(marketOwner);
vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);

market.createMarket(question, closeTime, resolutionTime, 0);

vm.expectRevert(MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime.selector);

market.createMarket("will rain fall", block.timestamp + 1000, block.timestamp, 0);

vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);

market.createMarket("", block.timestamp + 1000, block.timestamp + 1000, initialLiquidity);
vm.expectRevert(MarketFactory.MarketFactory__ZeroLiquidity.selector);

market.createMarket("will rain fall", block.timestamp + 1000, block.timestamp + 10001, 0);

vm.stopPrank();






}



function testCreateMarketPass()external{
    string memory question = "will rain fall";
uint256 closeTime = block.timestamp + 1000;
uint256 resolutionTime = block.timestamp + 20000;


vm.startPrank(marketOwner);
// come back here later
//vm.expectEmit();

 market.createMarket(question, closeTime, resolutionTime, initialLiquidity);

 vm.stopPrank();



}




}



