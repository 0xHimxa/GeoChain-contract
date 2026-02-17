# Test Suite Documentation

This directory contains the test suite for the GeoChain Prediction Market contracts.

## Test Organization

```
test/
├── unit/               # Unit tests for individual functions
│   └── PredictionMarket.t.sol
├── statelessFuzz/      # Property-based fuzz testing
│   └── predictionMarket.t.sol
├── statefullFuzz/      # Invariant/stateful fuzz testing (WIP)
└── README.md          # This file
```

## Running Tests

### All Tests

```bash
forge test
```

### With Verbosity

```bash
# -v: Show test results
# -vv: Show console.log output
# -vvv: Show stack traces for failures
# -vvvv: Show stack traces for all tests
# -vvvvv: Show internal traces
forge test -vv
```

### Specific Test File

```bash
forge test --match-path test/unit/PredictionMarket.t.sol
```

### Specific Test Function

```bash
forge test --match-test test_AddLiquidity_Success
```

### Gas Report

```bash
forge test --gas-report
```

### Coverage Report

```bash
forge coverage
```

### Detailed Coverage

```bash
forge coverage --report lcov
genhtml lcov.info --output-directory coverage
open coverage/index.html
```

## Test Types

### Unit Tests

Located in `test/unit/`, these tests verify individual contract functions in isolation.

**Naming Convention**: `test_FunctionName_Scenario()`

Examples:
- `test_AddLiquidity_Success()` - Happy path
- `testFail_AddLiquidity_InsufficientBalance()` - Expected failure
- `test_RevertWhen_AddLiquidity_ZeroAmount()` - Revert condition

**Structure**:
```solidity
function test_FunctionName_Scenario() public {
    // Setup: Prepare test state
    
    // Execute: Call function under test
    
    // Assert: Verify expected behavior
    assertEq(actual, expected);
}
```

### Fuzz Tests

Located in `test/statelessFuzz/`, these tests run with randomized inputs.

**Purpose**: Find edge cases and unexpected behaviors

**Example**:
```solidity
function testFuzz_Swap_AlwaysMaintainsK(uint256 swapAmount) public {
    // Bound inputs to valid ranges
    vm.assume(swapAmount > MIN && swapAmount < MAX);
    
    // Test with random input
    uint256 kBefore = market.yesReserve() * market.noReserve();
    market.swapYesForNo(swapAmount, 0);
    uint256 kAfter = market.yesReserve() * market.noReserve();
    
    // Invariant: k should increase or stay same (due to fees)
    assertGe(kAfter, kBefore);
}
```

### Invariant Tests (Coming Soon)

Located in `test/statefullFuzz/`, these tests verify that certain properties always hold.

**Invariants to Test**:
- Total supply of YES + NO tokens ≥ collateral locked
- Reserve product k never decreases
- Sum of LP shares matches totalShares
- Resolved markets maintain 1:1 redemption ratio

## Writing Tests

### Setup

Most tests inherit from a base test contract:

```solidity
contract PredictionMarketTest is Test {
    PredictionMarket public market;
    IERC20 public usdc;
    
    function setUp() public {
        // Deploy USDC mock
        usdc = new MockERC20("USDC", "USDC", 6);
        
        // Deploy market
        market = new PredictionMarket(
            "Test Question",
            address(usdc),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            address(this)
        );
        
        // Seed initial liquidity
        usdc.mint(address(market), 1000e6);
        market.seedLiquidity(1000e6);
    }
}
```

### Common Patterns

#### Testing Reverts

```solidity
function test_RevertWhen_ZeroAmount() public {
    vm.expectRevert(PredictionMarket__AmountCantBeZero.selector);
    market.mintCompleteSets(0);
}
```

#### Testing Events

```solidity
function test_EmitsEvent() public {
    vm.expectEmit(true, true, false, true);
    emit LiquidityAdded(user, yesAmount, noAmount, shares);
    market.addLiquidity(yesAmount, noAmount, 0);
}
```

#### Pranking (Impersonating Users)

```solidity
function test_AsUser() public {
    address user = makeAddr("user");
    
    vm.startPrank(user);
    market.mintCompleteSets(100e6);
    vm.stopPrank();
}
```

#### Time Manipulation

```solidity
function test_AfterClose() public {
    vm.warp(market.closeTime() + 1);
    // Market is now closed
}
```

### Coverage Goals

- **Line Coverage**: >90%
- **Branch Coverage**: >85%
- **Function Coverage**: 100% of public/external functions

### Critical Test Cases

Must have tests for:
- ✅ All public/external functions
- ✅ All revert conditions
- ✅ Access control modifiers
- ✅ State transitions
- ✅ Edge cases (zero amounts, max values)
- ✅ Reentrancy protection
- ✅ Fee calculations
- ✅ AMM mechanics (slippage, k invariant)

## Test Data

### Common Test Values (USDC with 6 decimals)

```solidity
uint256 constant ONE_USDC = 1e6;
uint256 constant TEN_USDC = 10e6;
uint256 constant HUNDRED_USDC = 100e6;
uint256 constant THOUSAND_USDC = 1000e6;

uint256 constant MINIMUM_AMOUNT = 1e6;       // 1 USDC
uint256 constant MINIMUM_SWAP = 970_000;    // 0.97 USDC
```

### Common Test Accounts

```solidity
address alice = makeAddr("alice");
address bob = makeAddr("bob");
address charlie = makeAddr("charlie");
```

## Continuous Integration

Tests should run on:
- Every commit
- Every pull request
- Before deployment

Example GitHub Actions workflow:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: forge test -vv
      - name: Check coverage
        run: forge coverage
```

## Debugging Failed Tests

### Increase Verbosity

```bash
forge test --match-test test名 -vvvv
```

### Use Console Logging

```solidity
import "forge-std/console.sol";

function test_Debug() public {
    console.log("yesReserve:", market.yesReserve());
    console.log("noReserve:", market.noReserve());
}
```

### Trace Execution

```bash
forge test --match-test testName --debug
```

## Best Practices

1. **Test One Thing**: Each test should verify one specific behavior
2. **Clear Names**: Test names should describe what they test
3. **Arrange-Act-Assert**: Follow AAA pattern for test structure
4. **Independent Tests**: Tests shouldn't depend on each other
5. **Clean State**: Use `setUp()` for fresh state each test
6. **Meaningful Assertions**: Use `assertEq`, `assertGt`, etc. with clear messages

## Resources

- [Foundry Book - Testing](https://book.getfoundry.sh/forge/tests)
- [Foundry Cheatcodes](https://book.getfoundry.sh/cheatcodes/)
- [Trail of Bits Testing Guide](https://github.com/crytic/building-secure-contracts/tree/master/program-analysis)

---

**Happy Testing!** 🧪
