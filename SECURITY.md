# Security Policy

## Reporting Security Vulnerabilities

**Please DO NOT file a public issue for security vulnerabilities.**

If you discover a security vulnerability in this project, please report it responsibly:

### Preferred Contact Method

Email: [your-security-email@example.com]

### What to Include

Please provide:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Timeline**: Depends on severity (critical issues prioritized)

## Security Considerations

### Known Security Aspects

#### 1. Centralized Resolution

**Risk**: Market outcome is determined by the market owner

**Mitigation**:
- Owner should be a trusted entity or DAO
- Consider implementing dispute mechanisms
- Document resolution criteria upfront

#### 2. Oracle-Free Pricing

**Risk**: Prices determined by AMM, not external oracle

**Mitigation**:
- This is a design choice for decentralization
- Users should understand AMM mechanics
- Arbitrageurs help maintain fair pricing

#### 3. Owner Privileges

The market owner can:
- Resolve the market outcome
- Pause/unpause the contract
- Seed initial liquidity

**Mitigation**:
- Clear documentation of owner powers
- Consider timelock for sensitive operations
- Multi-sig ownership recommended

### Attack Vectors and Mitigations

#### Reentrancy

**Protection**: All state-changing functions use OpenZeppelin's `ReentrancyGuard`

```solidity
function swap() external nonReentrant { ... }
```

**Status**: ✅ Protected

#### Front-Running

**Risk**: Traders can be front-run due to public mempool

**Mitigation**:
- Slippage protection on all trades
- Users can set minimum output amounts
- Consider private transaction services

**Status**: ⚠️ Partial mitigation

#### Griefing Attacks

**Risk**: Dust amounts could clog the system

**Mitigation**:
- Minimum amount requirements on operations
- `MINIMUM_AMOUNT = 1e6` (1 USDC)
- `MINIMUM_SWAP_AMOUNT = 970_000` (0.97 USDC)

**Status**: ✅ Protected

#### Price Manipulation

**Risk**: Large trades could manipulate market prices

**Mitigation**:
- AMM slippage naturally limits manipulation
- Complete sets provide arbitrage mechanism
- Liquidity depth determines resistance

**Status**: ✅ Design-level protection

#### Integer Overflow/Underflow

**Risk**: Arithmetic operations could overflow

**Mitigation**:
- Solidity 0.8.x has built-in overflow checks
- SafeMath not needed

**Status**: ✅ Protected

### Audit Status

**Static Analysis**: Analyzed with [Aderyn](https://github.com/Cyfrin/aderyn)
- Report: [report.md](./report.md)
- High issues: Addressed
- Low issues: Documented

**Professional Audit**: ❌ Not yet audited

**Recommendation**: Do not use in production without professional security audit

## Best Practices for Users

### For Market Creators

1. **Test Thoroughly**: Test on testnet before mainnet
2. **Use Multi-Sig**: Use multi-sig wallet for market ownership
3. **Set Reasonable Times**: Ensure sufficient time between close and resolution
4. **Document Resolution**: Publish clear resolution criteria
5. **Fund Adequately**: Provide sufficient initial liquidity

### For Traders

1. **Understand Risks**: This code is experimental
2. **Use Slippage Protection**: Always set `minOut` parameters
3. **Verify Markets**: Check market parameters before trading
4. **Start Small**: Test with small amounts first
5. **Check Allowances**: Review token approvals

### For Liquidity Providers

1. **Impermanent Loss**: Understand IL risks in AMM
2. **Resolution Risk**: LP positions at resolution may have unbalanced value
3. **Fee Earnings**: LPs earn from swap fees
4. **Withdrawal Timing**: Remove liquidity before market closes

## Emergency Procedures

### If You Discover a Vulnerability

1. **Do not exploit it**
2. **Report privately** (see reporting section)
3. **Do not disclose publicly** until fix is deployed
4. **Wait for fix** before public disclosure

### If a Vulnerability is Exploited

The market owner can:
1. **Pause the contract** immediately
2. **Assess damage** and impact
3. **Deploy fix** if possible
4. **Communicate** with affected users

## Smart Contract Security Resources

- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Consensys Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [Trail of Bits Security Guidelines](https://github.com/crytic/building-secure-contracts)
- [SWC Registry](https://swcregistry.io/)

## Bounty Program

Currently: ❌ No bounty program

Future: May establish bug bounty after audit

## Disclaimer

This software is provided "as is" without warranty. Use at your own risk. The developers are not responsible for any loss of funds.

---

**Last Updated**: 2026-02-12  
**Version**: 1.0.0
