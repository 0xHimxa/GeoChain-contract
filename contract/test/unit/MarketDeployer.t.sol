// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";

contract MarketDeployerTest is Test {
    MarketDeployer internal deployer;
    PredictionMarket internal implementation;
    OutcomeToken internal collateral;
    address internal owner = makeAddr("owner");
    address internal other = makeAddr("other");
    address internal forwarder = makeAddr("forwarder");

    function setUp() external {
        implementation = new PredictionMarket();
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        deployer = new MarketDeployer(address(implementation), owner);
    }

    function testConstructorValidation() external {
        vm.expectRevert(MarketDeployer.MarketDeployer__ZeroImplementation.selector);
        new MarketDeployer(address(0), owner);

        vm.expectRevert(MarketDeployer.MarketDeployer__ZeroImplementation.selector);
        new MarketDeployer(address(implementation), address(0));
    }

    function testSetImplementationValidationAndPass() external {
        vm.prank(other);
        vm.expectRevert(MarketDeployer.MarketDeployer__OnlyOwner.selector);
        deployer.setImplementation(address(implementation));

        vm.prank(owner);
        vm.expectRevert(MarketDeployer.MarketDeployer__ZeroImplementation.selector);
        deployer.setImplementation(address(0));

        PredictionMarket newImplementation = new PredictionMarket();
        vm.prank(owner);
        deployer.setImplementation(address(newImplementation));
        assertEq(deployer.marketImplementation(), address(newImplementation));
    }

    function testSetNewOwnerValidationAndPass() external {
        vm.prank(other);
        vm.expectRevert(MarketDeployer.MarketDeployer__OnlyOwner.selector);
        deployer.setNewOwner(other);

        vm.prank(owner);
        vm.expectRevert(MarketDeployer.MarketDeployer__NewOwnerCantBeAddressZero.selector);
        deployer.setNewOwner(address(0));

        vm.prank(owner);
        deployer.setNewOwner(other);
        assertEq(deployer.owner(), other);
    }

    function testDeployPredictionMarketOnlyOwnerAndPass() external {
        vm.prank(other);
        vm.expectRevert(MarketDeployer.MarketDeployer__OnlyOwner.selector);
        deployer.deployPredictionMarket(
            "q",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            forwarder
        );

        vm.prank(owner);
        address deployed = deployer.deployPredictionMarket(
            "Will ETH > 5k?",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            forwarder
        );
        assertTrue(deployed != address(0));
    }
}
