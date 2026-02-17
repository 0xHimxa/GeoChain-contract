# Contributing to GeoChain Prediction Market

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Code of Conduct

- Be respectful and constructive
- Welcome newcomers and help them get started
- Focus on what is best for the community

## Development Process

### 1. Setting Up Your Environment

```bash
# Fork and clone the repository
git clone https://github.com/your-username/GeoChain-contract.git
cd GeoChain-contract/contracts

# Install dependencies
forge install

# Build the project
forge build

# Run tests
forge test
```

### 2. Making Changes

1. **Create a branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following our coding standards

3. **Write tests** for new functionality

4. **Run the test suite**:
   ```bash
   forge test -vv
   ```

5. **Run static analysis**:
   ```bash
   aderyn ./src
   ```

6. **Commit your changes** with clear commit messages:
   ```bash
   git commit -m "feat: add new feature description"
   ```

## Coding Standards

### Solidity Style Guide

Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html) and these additional conventions:

#### File Organization

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Imports grouped by source
import {OpenZeppelinContract} from "@openzeppelin/...";
import {LocalContract} from "./LocalContract.sol";

// Contract structure:
// 1. Type declarations (enums, structs)
// 2. State variables
// 3. Events
// 4. Errors
// 5. Modifiers
// 6. Constructor
// 7. External functions
// 8. Public functions
// 9. Internal functions
// 10. Private functions
```

#### Naming Conventions

- **Contracts**: PascalCase (e.g., `MarketFactory`, `PredictionMarket`)
- **Functions**: camelCase (e.g., `addLiquidity`, `swapYesForNo`)
- **Variables**:
  - State variables: camelCase with prefix
    - Storage: `s_variableName`
    - Immutable: `i_variableName`
    - Constant: `UPPER_SNAKE_CASE`
  - Local variables: camelCase
  - Function parameters: camelCase with `_` suffix
- **Errors**: `ContractName__ErrorDescription` (e.g., `PredictionMarket__AmountCantBeZero`)
- **Events**: PascalCase (e.g., `LiquidityAdded`, `MarketResolved`)

#### Documentation

All public and external functions must have NatSpec comments:

```solidity
/**
 * @notice Brief description for users
 * @dev Technical details for developers
 * @param paramName Description of the parameter
 * @return returnName Description of return value
 */
function myFunction(uint256 paramName) external returns (uint256 returnName) {
    // Implementation
}
```

#### Gas Optimization

- Use `immutable` for variables set only in constructor
- Use custom errors instead of string reverts
- Use `calldata` for read-only function parameters
- Pack storage variables when possible
- Consider using `unchecked` blocks where overflow is impossible

#### Security Best Practices

- Follow the Checks-Effects-Interactions pattern
- Use `nonReentrant` modifier for functions with external calls
- Validate all inputs
- Use SafeERC20 for token transfers
- Include slippage protection on AMM operations
- Add comprehensive error messages

### Testing Standards

#### Unit Tests

- Test each function in isolation
- Cover happy paths and edge cases
- Test access control
- Test error conditions

```solidity
function test_AddLiquidity_Success() public {
    // Setup
    
    // Execute
    
    // Assert
}

function testFail_AddLiquidity_InsufficientBalance() public {
    // Test failure case
}
```

#### Fuzz Tests

- Test with random inputs
- Define invariants that should always hold
- Use reasonable input bounds

```solidity
function testFuzz_Swap(uint256 amount) public {
    vm.assume(amount > MINIMUM_SWAP && amount < MAX_REASONABLE);
    // Test with fuzzed amount
}
```

#### Coverage Requirements

- Aim for >90% line coverage
- Prioritize critical paths and edge cases
- Run coverage report: `forge coverage`

## Pull Request Process

### Before Submitting

- [ ] All tests pass: `forge test`
- [ ] Static analysis clean: `aderyn ./src`
- [ ] Code follows style guide
- [ ] New functions documented with NatSpec
- [ ] Added tests for new functionality
- [ ] Updated README/docs if needed

### PR Guidelines

1. **Title**: Use conventional commits format
   - `feat:` for new features
   - `fix:` for bug fixes
   - `docs:` for documentation
   - `refactor:` for code refactoring
   - `test:` for test changes
   - `chore:` for maintenance tasks

2. **Description**: Include:
   - What changed and why
   - How to test the changes
   - Any breaking changes
   - Related issues (if applicable)

3. **Size**: Keep PRs focused and reasonably sized
   - Break large changes into multiple PRs
   - Each PR should be independently reviewable

### Review Process

1. Automated checks must pass
2. At least one maintainer approval required
3. Address all review comments
4. Squash commits before merging

## Reporting Bugs

### Security Vulnerabilities

**DO NOT** open a public issue for security vulnerabilities. See [SECURITY.md](./SECURITY.md) for responsible disclosure.

### Bug Reports

Include:
- Clear description of the issue
- Steps to reproduce
- Expected vs actual behavior
- Environment details (Solidity version, Foundry version)
- Relevant logs or error messages

## Feature Requests

Open an issue with:
- Clear use case description
- Proposed solution (if any)
- Alternatives considered
- Impact on existing functionality

## Questions?

- Open a discussion on GitHub
- Check existing issues and documentation
- Join our community chat (if available)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to GeoChain Prediction Market! 🎉
