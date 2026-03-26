# RWA Real Estate — Smart Contracts

Solidity contracts for a Real World Asset (RWA) investment platform. Investors fund
US real estate construction projects using USDC on Base. Each project is backed by a
security token. KYC is enforced on-chain. ROI is distributed via Merkle tree when
construction completes.

---

## How It Works

### Actors

| Actor | Address | Role |
|---|---|---|
| **Admin** | Gnosis Safe 3-of-5 | Creates projects, triggers state transitions, withdraws funds |
| **Attester** | NestJS hot wallet | Issues and revokes KYC attestations after off-chain verification |
| **Investor (US)** | Wallet | Reg D 506(c) — must be an accredited investor |
| **Investor (non-US)** | Wallet | Reg S — non-US person, identity + sanctions checked |
| **Multisig** | Gnosis Safe | Receives raised USDC for fiat conversion |

---

### Contract Overview

```
KYCRegistry
  Stores on-chain attestations for every verified investor.
  Two tracks: accredited investor (Reg D) and Reg S eligible (non-US).
  Read by every other contract before any money moves.

PropertyToken  (one deployed per project)
  ERC-20 security token. Minted to investors on investment.
  KYC compliance hook: every wallet-to-wallet transfer checks the
  recipient's attestation. Mint and burn bypass this check.
  Transfers between investors are locked during construction (v1).

PropertyFunding  (one deployed per project)
  Accepts USDC investments, mints PropertyTokens.
  Runs the project state machine.
  Anyone can trigger refund mode once deadline passes with goal unmet.

PropertyFundingFactory
  Admin entry point. Deploys a matched PropertyToken + PropertyFunding
  pair, wires up roles, then relinquishes its own privileges.

ROIDistributor
  Accepts a USDC deposit from admin (principal + ROI for all investors).
  Uses a Merkle tree so investors claim individually — no gas-heavy loops.
  Burns PropertyTokens on claim.
```

---

### Project State Machine

A project moves through these states in order. No state can be skipped or reversed.

```
FUNDRAISING
    │
    ├─ (goal met during invest()) ──────────────────► FUNDED
    │                                                     │
    │                                          (admin withdrawFunds())
    │                                                     │
    │                                                 WITHDRAWN
    │                                                     │
    │                                           (admin setActive())
    │                                                     │
    │                                                  ACTIVE
    │                                                     │
    │                                          (admin setCompleted())
    │                                                     │
    │                                                COMPLETED
    │                                          (ROIDistributor takes over)
    │
    └─ (deadline passed, goal not met) ─────────────► REFUNDING
                                                          │
                                                (investors claimRefund())
                                                          │
                                                       REFUNDED
```

State | Who triggers | What happens
------|--------------|-------------
`FUNDRAISING` | — | Open for investment. Anyone with valid KYC can invest.
`FUNDED` | Auto (last invest that hits goal) | Goal met. Admin can now withdraw.
`WITHDRAWN` | `admin.withdrawFunds()` | USDC sent to Gnosis Safe → Coinbase Prime → fiat.
`ACTIVE` | `admin.setActive()` | Confirms fiat conversion done, construction started.
`COMPLETED` | `admin.setCompleted()` | Construction done. ROIDistributor handles payouts.
`REFUNDING` | Anyone calls `triggerRefund()` | Deadline passed, goal unmet. Investors claim back.
`REFUNDED` | Informational | All refunds claimed.

---

### Investment Flow (Investor perspective)

```
1. Complete KYC
     US investor  → Synaps (identity) + Parallel Markets (accredited investor check)
     non-US       → Synaps only (identity + sanctions)

2. Backend issues EAS attestation on-chain for your wallet

3. Approve USDC spend
     usdc.approve(propertyFundingAddress, amount)

4. Call invest()
     funding.invest(usdcAmount)
     → Contract checks: KYC valid? Deadline not passed? Above minimum? State = FUNDRAISING?
     → USDC pulled from your wallet into the contract
     → PropertyTokens minted to your wallet (1 USDC = 1 token, scaled for decimals)
     → If total raised hits funding goal: state transitions to FUNDED automatically

5. Wait during construction
     Tokens are locked (non-transferable) while the project is ACTIVE.

6. Claim ROI when project completes
     distributor.claim(projectAddress, claimableAmount, merkleProof)
     → Merkle proof fetched from backend: GET /api/projects/{id}/proof/{wallet}
     → USDC (principal + ROI) transferred to your wallet
     → PropertyTokens burned
```

---

### Refund Flow (when project fails to raise enough)

```
1. Deadline passes with totalRaised < fundingGoal
2. Anyone calls funding.triggerRefund() — no admin required, trustless
3. Each investor calls funding.claimRefund()
   → Their investment is returned in full
   → Their PropertyTokens are burned
```

---

### ROI Distribution (Merkle tree)

Why Merkle and not a simple loop? A loop over 100+ investors can hit the block gas limit
and is vulnerable to griefing (one bad address reverts the whole payout). Merkle lets
each investor claim independently at their own gas cost.

```
Admin workflow when project completes:
  1. Read all investors and their investment amounts from on-chain events
  2. Compute each investor's claimable USDC:
       claimable = investment + (investment * roiBps / 10_000)
  3. Build Merkle tree: leaf = keccak256(abi.encodePacked(wallet, claimableAmount))
  4. Call distributor.depositReturns(projectAddress, merkleRoot, totalUSDC)

Investor workflow:
  1. GET /api/projects/{id}/proof/{wallet} → { claimableAmount, proof[] }
  2. Call distributor.claim(projectAddress, claimableAmount, proof)
```

---

### KYC Registry

Every operation that moves money or tokens checks `KYCRegistry` first.

```
isVerified(wallet)         → kycPassed && !revoked && block.timestamp < expiresAt
isAccredited(wallet)       → isVerified + accreditedInvestor flag (Reg D)
isRegSEligible(wallet)     → isVerified + regSEligible flag (Reg S)
isEligibleInvestor(wallet) → isAccredited || isRegSEligible
```

Attestations expire (max 1 year). The backend sends renewal emails 30 days before expiry.
On PM webhook `accreditation.expired`: backend calls `registry.revokeAttestation(wallet)`.

The `pmIdHashToWallet` mapping (`keccak256(pmInvestorId) → wallet`) lets the backend
reverse-lookup which wallet a Parallel Markets webhook refers to without storing PII
in the contract.

---

### Security Model

**Access control** (OpenZeppelin `AccessControl`):

| Role | Holder | Can do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Hardware wallet / Gnosis Safe | Manage all roles |
| `ADMIN_ROLE` | Gnosis Safe 3-of-5 | State transitions, fund withdrawal, ROI deposit |
| `ATTESTER_ROLE` | NestJS hot wallet | Issue / revoke / update attestations |
| `PAUSER_ROLE` | Gnosis Safe | Emergency pause all contracts |
| `MINTER_ROLE` | PropertyFunding + ROIDistributor | Mint/burn PropertyTokens |

**Reentrancy**: All fund-moving functions carry `nonReentrant`. The invest / refund
functions also follow Checks-Effects-Interactions — state is zeroed before any external
call, so a reentrant attempt finds nothing to claim even if the lock were bypassed.

**ERC-3643 compliance pattern**: `PropertyToken._update()` rejects wallet-to-wallet
transfers where the recipient is not KYC-verified. Mint (`from == 0`) and burn
(`to == 0`) bypass this check intentionally — they are internal operations.

**Note**: This is an ERC-3643-*inspired* pattern, not full T-REX standard compliance.
See [Next Steps](#next-steps) for the migration path.

---

## Project Structure

```
rwa/
├── src/
│   ├── interfaces/
│   │   └── IKYCRegistry.sol          interface consumed by PropertyToken + PropertyFunding
│   ├── KYCRegistry.sol               on-chain KYC attestation store
│   ├── PropertyToken.sol             ERC-20 security token, one per project
│   ├── PropertyFunding.sol           investment + state machine, one per project
│   ├── PropertyFundingFactory.sol    deploys token+funding pairs, wires roles
│   └── ROIDistributor.sol            Merkle-based principal + ROI payouts
│
├── test/
│   ├── mocks/
│   │   ├── MockUSDC.sol              6-decimal ERC-20 for local tests
│   │   └── MaliciousUSDC.sol         reentrancy attack simulator
│   ├── BaseTest.t.sol                shared setUp, actors, helpers
│   ├── KYCRegistry.t.sol             unit + fuzz tests for registry
│   ├── PropertyToken.t.sol           unit + fuzz tests for token compliance
│   ├── PropertyFunding.t.sol         unit + fuzz + lifecycle integration tests
│   ├── ROIDistributor.t.sol          Merkle claim tests
│   └── Attacker.t.sol                36 adversarial tests (all must PASS = contract rejects attack)
│
└── script/
    └── Deploy.s.sol                  deploys KYCRegistry + ROIDistributor + Factory
```

---

## Dependencies

```toml
# foundry.toml
[profile.default]
solc     = "0.8.24"
via_ir   = true          # required: PropertyFunding has many constructor params
optimizer = true
optimizer_runs = 200
```

| Dependency | Version | Purpose |
|---|---|---|
| `OpenZeppelin/openzeppelin-contracts` | latest | ERC20, AccessControl, ReentrancyGuard, Pausable, MerkleProof, SafeERC20 |
| `foundry-rs/forge-std` | latest | Test utilities, cheatcodes, console2 |

---

## Running Tests

```bash
# All tests
forge test

# With gas reporting
forge test --gas-report

# Single suite
forge test --match-path "test/Attacker.t.sol" -vv

# Single test
forge test --match-test "test_Attack_ReentrancyOnClaimRefund" -vvvv

# Fuzz with more runs
forge test --match-test "testFuzz" --fuzz-runs 1000
```

Current coverage: **92 tests, 0 failing**

| Suite | Tests | Notes |
|---|---|---|
| `KYCRegistry.t.sol` | 15 | includes `testFuzz_IssueAndVerify` (256 runs) |
| `PropertyToken.t.sol` | 11 | includes `testFuzz_MintBurn_BalanceConsistency` |
| `PropertyFunding.t.sol` | 20 | includes 2 fuzz tests + full lifecycle integration |
| `ROIDistributor.t.sol` | 10 | Merkle proof correctness + double-claim prevention |
| `Attacker.t.sol` | 36 | All attacks must be **rejected** — PASS = contract is safe |

---

## Deployment

### Prerequisites

```bash
# Required env vars (.env)
DEPLOYER_KEY=0x...          # private key funding gas
ADMIN_ADDRESS=0x...         # Gnosis Safe address
ATTESTER_ADDRESS=0x...      # NestJS hot wallet
USDC_ADDRESS=0x...          # USDC on target chain

# Base Sepolia USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
# Base mainnet USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

### Deploy to Base Sepolia

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### After deployment — first project

```bash
# Call factory.createProject() from the admin (Gnosis Safe)
cast send $FACTORY_ADDRESS \
  "createProject(string,string,address,uint256,uint256,uint256,uint256,uint256,uint256,string)" \
  "PropToken LA-2024-01" "PROP-LA-01" \
  $MULTISIG_ADDRESS \
  200000000000 \           # fundingGoal: $200,000 USDC (6 decimals)
  $(($(date +%s) + 2592000)) \  # deadline: 30 days from now
  1500 \                   # expectedROIBps: 15%
  $(($(date +%s) + 5184000)) \  # estimatedStart: 60 days
  $(($(date +%s) + 46656000)) \ # estimatedEnd: ~18 months
  2000000000 \             # minInvestment: $2,000 USDC
  "ipfs://QmYourCIDHere" \
  --rpc-url base_sepolia \
  --private-key $DEPLOYER_KEY
```

### Useful cast commands

```bash
# Check if wallet is KYC'd
cast call $REGISTRY "isEligibleInvestor(address)" $WALLET --rpc-url base_sepolia

# Check project state (0=FUNDRAISING 1=FUNDED 2=WITHDRAWN 3=ACTIVE 4=COMPLETED 5=REFUNDING)
cast call $FUNDING "state()" --rpc-url base_sepolia

# Check total raised
cast call $FUNDING "totalRaised()" --rpc-url base_sepolia

# Check investor balance
cast call $TOKEN "balanceOf(address)" $WALLET --rpc-url base_sepolia
```

---

## Next Steps

### v2 — Full ERC-3643 (T-REX) Migration

The current `PropertyToken` implements the ERC-3643 *compliance pattern* manually.
It is not compliant with the actual standard. Migrating to full T-REX enables:

- Interoperability with institutional RWA marketplaces (Tokeny, etc.)
- `supportsInterface(IERC3643)` returns true
- Pluggable compliance modules (country restrictions, max balance, transfer fees)
- ONCHAINID identity system (portable across chains)

**Migration steps:**

```bash
forge install TokenySolutions/T-REX --no-git
```

1. Replace `PropertyToken extends ERC20` with `Token extends IToken` from T-REX
2. Replace `KYCRegistry` with Tokeny's `IdentityRegistry` + `ClaimTopicsRegistry` + `TrustedIssuersRegistry`
3. Replace our single `isVerified()` check with `ModularCompliance` modules:
   - `CountryAllowModule` — handles Reg S OFAC country restrictions
   - `MaxBalanceModule` — enforce per-investor caps (Reg CF limits)
4. Map EAS attestations → ONCHAINID claims (or replace EAS with ONCHAINID directly)

### v2 — Secondary Market

Enable token transfers between KYC-verified investors:

```solidity
// PropertyToken.sol — currently locked
function enableTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
    transfersEnabled = true; // already implemented, just needs calling
}
```

Legal requirement: check whether running a secondary market requires ATS
(Alternative Trading System) registration with FINRA before enabling.

### v2 — UUPS Upgradeable Proxies

`KYCRegistry` and `PropertyToken` will need updates as regulations evolve.
Wrap both with OpenZeppelin's UUPS proxy pattern:

```bash
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-git
```

Replace `AccessControl` with `AccessControlUpgradeable`, add `initialize()`,
deploy behind `ERC1967Proxy`. Discuss the upgrade mechanism with your auditor
before deploying to mainnet — upgradeable contracts carry their own risks.

### v2 — ERC-4337 Account Abstraction (Gasless UX)

Investors should not need to hold ETH for gas. Base supports ERC-4337 natively.
Use Coinbase's Paymaster to sponsor gas for `invest()` and `claim()` calls.
Investors only need USDC in their wallet.

### Mandatory before mainnet

- [ ] Professional smart contract audit (Code4rena contest or Trail of Bits)
- [ ] Gnosis Safe deployed and tested on testnet with real signers
- [ ] Coinbase Prime KYB approved
- [ ] Securities attorney sign-off on Reg D 506(c) + Reg S dual offering structure
- [ ] EAS schema registered on Base mainnet
- [ ] Parallel Markets + Synaps sandbox → production credentials
