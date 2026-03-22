# PRD: stETH Agent Treasury

**Version:** 1.2 | **Date:** 2026-03-21 | **Bounty:** $2,000 (1st) + $1,000 (2nd)

---

## 1. Executive Summary

### What We're Building

A Solidity contract primitive — **AgentTreasury** — that lets a human give an AI agent a yield-bearing operating budget backed by wstETH, without ever giving the agent access to the principal. Only staking yield flows to the agent's spendable balance, with spending permissions enforced at the contract level. The agent uses this yield to pay for real services via the Machine Payments Protocol (MPP).

### Why It Matters

Autonomous AI agents need operating budgets, but giving them unrestricted access to funds is a trust problem. By backing the budget with stETH staking yield (~3.5% APR), the human's principal remains structurally locked while the agent gets a self-replenishing budget. This is the primitive for "give an AI a credit card with yield-funded spending limits."

### Target Bounty

Lido stETH Agent Treasury — $3,000 total ($2,000 first, $1,000 second). Must demonstrate: principal isolation, spendable yield balance, configurable permissions, no mocks, working payment demo.

---

## 2. Architecture Overview

### System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        HUMAN (Owner)                            │
│  Deposits wstETH, sets permissions, can withdraw principal      │
└──────────────────────────┬──────────────────────────────────────┘
                           │ deposit() / withdrawPrincipal()
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                   AgentTreasury.sol (Base)                       │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │  Principal    │  │  Yield       │  │  Permissions          │ │
│  │  Tracking     │  │  Calculation │  │  - Whitelist          │ │
│  │  (wstETH)     │  │  via Rate    │  │  - Per-tx cap         │ │
│  │              │  │  Oracle      │  │  - Daily limit        │ │
│  └──────────────┘  └──────────────┘  └───────────────────────┘ │
│                           │                                     │
│                    claimYield() [agent only]                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                     AI AGENT (Node.js)                           │
│  Queries yield → claims wstETH → pays for services via MPP     │
│                                                                 │
│  ┌─────────────┐     ┌──────────────────────────────────┐      │
│  │ mppx client │────>│ Custom MPP Payment Method         │      │
│  │ (402 flow)  │     │ "wsteth-yield" on Base            │      │
│  └─────────────┘     └──────────────────────────────────┘      │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP 402 → Credential (tx hash) → Receipt
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                  MPP Demo Service (Hono/Express)                │
│  Verifies on-chain payment → proxies to real API → returns data │
│  (Image gen, web search, LLM inference)                         │
└─────────────────────────────────────────────────────────────────┘
```

### Chain Selection: Base (Chain ID 8453)

**Decision: Base**

| Factor | Base | Ethereum | Arbitrum | Optimism |
|--------|------|----------|----------|----------|
| Gas per contract call | ~$0.05-0.15 | ~$5.48 | ~$0.27 | ~$0.18 |
| wstETH holders | 468,304 | 36,353 | 43,359 | 29,047 |
| wstETH market cap | $165M | $9.03B | $170M | $54M |
| wstETH contract type | ERC20Bridged (proxy) | Native (has `stEthPerToken()`) | ERC20Bridged | ERC20BridgedPermit |
| Tooling | Excellent | Best | Great | Great |

**Justification:**
1. **Lowest gas for interactive demo** — dozens of transactions during a live demo cost pennies
2. **Largest wstETH holder count** on any L2 (468K), demonstrating ecosystem adoption
3. **Excellent tooling** — first-class Foundry, Hardhat, viem support
4. **Known trade-off**: Base wstETH is `ERC20Bridged` and lacks `stEthPerToken()`. We solve this with an owner-updatable rate oracle (see Section 3).

**On-chain verification** (via Blockscout):
- wstETH: `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` — verified, EIP-1967 proxy → `ERC20Bridged`
- Total supply: 35,886 wstETH, exchange rate ~$2,637/wstETH

---

## 3. Smart Contract Specification

### 3.1 Contract: `AgentTreasury`

**Compiler:** Solidity 0.8.20+
**Inheritance:** `AccessControl`, `ReentrancyGuard`, `Pausable`
**Immutability:** Non-upgradeable (no proxy). Provides stronger trust guarantees.

### 3.2 Roles

| Role | Constant | Who | Capabilities |
|------|----------|-----|--------------|
| **Owner** | `OWNER_ROLE` | Human wallet (EOA/multisig) | Deposit/withdraw principal, set permissions, manage agent, pause/unpause |
| **Agent** | `AGENT_ROLE` | AI agent's EOA | Query yield, claim yield within permission bounds |
| **Guardian** | `GUARDIAN_ROLE` | Optional trusted party | Emergency pause only, cannot touch funds |

Role hierarchy: `DEFAULT_ADMIN_ROLE` (deployer) is admin for all roles. Renounced after setup.

### 3.3 Storage Layout

```solidity
// === IMMUTABLES ===
IERC20 public immutable wstETH;           // wstETH token on Base

// === RATE ORACLE ===
IRateOracle public rateOracle;             // wstETH→stETH rate source

// === PRINCIPAL TRACKING ===
uint256 public wstETHDeposited;            // total wstETH deposited (W)
uint256 public initialRate;                // stEthPerToken at deposit time (R₀), 18 decimals
uint256 public pendingYieldBonus;          // unclaimed yield carried over from re-anchoring, in wstETH
uint256 public totalYieldClaimed;          // cumulative yield claimed in wstETH

// === PERMISSIONS: WHITELIST ===
mapping(address => bool) public whitelistedRecipients;

// === PERMISSIONS: CAPS ===
uint256 public maxPerTransaction;          // max wstETH per claim, 0 = unlimited

// === PERMISSIONS: TIME-WINDOWED SPENDING ===
uint256 public spendingLimit;              // max wstETH per window, 0 = unlimited
uint256 public spendingWindow;             // window duration in seconds
uint256 public windowStart;                // current window start timestamp
uint256 public spentInCurrentWindow;       // wstETH spent in current window

// === PERMISSIONS: COOLDOWN ===
uint256 public cooldownPeriod;             // seconds between claims, 0 = disabled
uint256 public lastClaimTimestamp;         // timestamp of last claim
```

### 3.4 Yield Calculation Mechanism

**Core Math:**

Let:
- `W` = `wstETHDeposited` (fixed while locked)
- `R₀` = `initialRate` (stEthPerToken at deposit time)
- `Rₜ` = current `stEthPerToken()` from rate oracle

**Accrued yield in wstETH:**
```
Y_wstETH = W × (Rₜ - R₀) / Rₜ
```

**Available yield (accounting for prior claims):**
```
available = Y_wstETH + pendingYieldBonus - totalYieldClaimed
```

**Proof of principal preservation:**
After claiming `Y_wstETH`, remaining wstETH = `W - Y_wstETH = W × R₀ / Rₜ`. Its stETH value = `(W × R₀ / Rₜ) × Rₜ / 1e18 = W × R₀ / 1e18 = P` (original principal). QED.

**Negative rebase handling:** If `Rₜ ≤ R₀`, yield = 0 (no revert, agent simply cannot claim).

**Multiple deposits:** Re-anchor approach — before updating, compute unclaimed yield as `pendingYieldBonus`, then reset `initialRate = currentRate` and `totalYieldClaimed = 0`.

**Numerical example:**
- Deposit 100 wstETH when rate = 1.20 (principal = 120 stETH)
- 6 months later, rate = 1.22 (+1.67%)
- Yield = 100 × (1.22 - 1.20) / 1.22 = 1.639 wstETH (~2 stETH)
- After claiming: 98.361 wstETH × 1.22 = 120.0 stETH (principal preserved)

### 3.5 Rate Oracle (L2 Requirement)

On Base, wstETH is a bridged ERC-20 without `stEthPerToken()`. We use an owner-updatable rate oracle:

```solidity
interface IRateOracle {
    function getRate() external view returns (uint256); // stETH per wstETH, 18 decimals
}

contract RateOracle is IRateOracle {
    uint256 public rate;
    address public updater;
    uint256 public lastUpdated;

    function setRate(uint256 _rate) external;  // onlyUpdater
    function getRate() external view returns (uint256);
}
```

The owner (or automated keeper) pushes the current L1 `stEthPerToken()` value to this oracle. For the hackathon, manual updates suffice. In production, a Chainlink wstETH/stETH feed would replace this.

### 3.6 Complete Function Signatures

#### Core Functions

```solidity
// === DEPOSIT (Owner only) ===
function deposit(uint256 amount) external onlyRole(OWNER_ROLE) nonReentrant whenNotPaused;
function depositETH() external payable onlyRole(OWNER_ROLE) nonReentrant whenNotPaused;

// === WITHDRAW PRINCIPAL (Owner only) ===
function withdrawPrincipal(uint256 amount, address to) external onlyRole(OWNER_ROLE) nonReentrant;
function emergencyWithdraw(address to) external onlyRole(OWNER_ROLE) nonReentrant;

// === YIELD QUERIES (Public view) ===
function getAvailableYield() public view returns (uint256 wstETHAmount);
function getAvailableYieldInStETH() public view returns (uint256 stETHAmount);
function getPrincipalValue() public view returns (uint256 stETHAmount);
function getTotalValue() public view returns (uint256 stETHAmount);

// === CLAIM YIELD (Agent only) ===
function claimYield(uint256 amount, address recipient)
    external onlyRole(AGENT_ROLE) nonReentrant whenNotPaused;

// === PERMISSION MANAGEMENT (Owner only) ===
function addRecipient(address recipient) external onlyRole(OWNER_ROLE);
function removeRecipient(address recipient) external onlyRole(OWNER_ROLE);
function setMaxPerTransaction(uint256 amount) external onlyRole(OWNER_ROLE);
function setSpendingLimit(uint256 limit, uint256 window) external onlyRole(OWNER_ROLE);
function setCooldownPeriod(uint256 period) external onlyRole(OWNER_ROLE);

// === ROLE MANAGEMENT (Owner only) ===
function setAgent(address newAgent) external onlyRole(OWNER_ROLE);
function setGuardian(address newGuardian) external onlyRole(OWNER_ROLE);

// === EMERGENCY ===
function pause() external;  // OWNER_ROLE or GUARDIAN_ROLE
function unpause() external onlyRole(OWNER_ROLE);
```

#### `claimYield` Logic (Pseudocode)

```
1. require(whitelistedRecipients[recipient])
2. require(amount <= getAvailableYield())
3. require(maxPerTransaction == 0 || amount <= maxPerTransaction)
4. enforceSpendingWindow(amount)
5. enforceCooldown()
6. totalYieldClaimed += amount          // Effects before interactions
7. wstETH.safeTransfer(recipient, amount)
8. assert(wstETH.balanceOf(this) >= principalWstETHFloor())  // Belt-and-suspenders
9. emit YieldClaimed(agent, amount, recipient)
```

### 3.7 Events

```solidity
event Deposited(address indexed owner, uint256 wstETHAmount, uint256 rateAtDeposit);
event PrincipalWithdrawn(address indexed owner, uint256 wstETHAmount, address indexed to);
event YieldClaimed(address indexed agent, uint256 wstETHAmount, address indexed recipient);
event AgentUpdated(address indexed oldAgent, address indexed newAgent);
event RecipientWhitelisted(address indexed recipient, bool status);
event MaxPerTransactionUpdated(uint256 oldValue, uint256 newValue);
event SpendingLimitUpdated(uint256 limit, uint256 window);
event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
event Paused(address indexed by);
event Unpaused(address indexed by);
```

### 3.8 Principal Isolation Guarantees

Principal isolation is enforced **structurally**, not by policy:

1. **No agent-callable function can move principal.** The only token-moving function available to the agent is `claimYield()`, which is mathematically bounded by the yield formula.
2. **Yield formula caps extraction.** `amount ≤ W × (Rₜ - R₀) / Rₜ - totalYieldClaimed` — impossible to exceed yield.
3. **Post-condition assertion.** Every `claimYield` call verifies `wstETH.balanceOf(this) >= principalWstETHFloor()` using ceiling division (conservative rounding).
4. **No delegatecall, no generic execute.** The agent has no way to craft arbitrary transactions through the contract.
5. **No approval exposure.** The contract never approves external contracts to spend its wstETH on the agent's behalf.

### 3.9 Permission System Design

| Permission | Type | Default | Enforcement |
|------------|------|---------|-------------|
| Recipient whitelist | `mapping(address => bool)` | Empty (no one whitelisted) | Revert if `!whitelistedRecipients[recipient]` |
| Per-transaction cap | `uint256` | 0 (unlimited) | Revert if `amount > maxPerTransaction && maxPerTransaction != 0` |
| Time-windowed limit | `uint256` + `uint256` | 0 (unlimited) | Reset window if expired; revert if `spentInWindow + amount > limit` |
| Cooldown | `uint256` | 0 (disabled) | Revert if `block.timestamp < lastClaim + cooldown` |

All permissions are independently configurable and default to "no restriction" when set to zero. The whitelist defaults to empty (fully restrictive).

---

## 4. Additional Contracts

### 4.1 RateOracle.sol

**Purpose:** Provides `stEthPerToken()` equivalent on Base where the bridged wstETH lacks this function.

```solidity
contract RateOracle is IRateOracle, Ownable {
    uint256 public rate;
    uint256 public lastUpdated;

    function setRate(uint256 _rate) external onlyOwner {
        require(_rate > 0, "Invalid rate");
        rate = _rate;
        lastUpdated = block.timestamp;
        emit RateUpdated(_rate, block.timestamp);
    }

    function getRate() external view returns (uint256) {
        return rate;
    }
}
```

**Update strategy:** Owner reads `stEthPerToken()` from mainnet (via Etherscan, RPC, or script) and pushes to the oracle. Rate changes ~once daily when Lido oracle reports. For hackathon, manual updates are sufficient.

**Production path:** Replace with Chainlink wstETH/stETH feed or a cross-chain messaging oracle (LayerZero, CCIP).

### 4.2 AgentTreasuryFactory.sol (Optional)

For deploying multiple treasuries:

```solidity
contract AgentTreasuryFactory {
    event TreasuryCreated(address indexed treasury, address indexed owner, address indexed agent);
    function createTreasury(address agent, address rateOracle) external returns (address);
    function createTreasuryAndDeposit(address agent, address rateOracle, uint256 wstETHAmount) external returns (address);
}
```

### 4.3 No Swap Contract Needed for MVP

The agent receives yield as wstETH and the self-hosted MPP gateway accepts wstETH directly on Base. No DEX integration needed for the hackathon. In production, a `YieldSwapper` using Uniswap V3 (wstETH → WETH → USDC) would enable spending in stablecoins.

---

## 5. Payment Protocol Integration Plan

### 5.1 Protocol Landscape (March 2026)

Two competing HTTP 402 payment protocols exist:

| | **x402 (Coinbase)** | **MPP (Tempo/Stripe)** |
|---|---|---|
| Settlement chain | **Base, Polygon, Solana, any EVM** | Tempo chain (ID 4217) only |
| Base support | **Native** (`eip155:8453`) | None (requires custom method) |
| Token support | USDC (EIP-3009), **any ERC-20 (Permit2)** | TIP-20 stablecoins on Tempo |
| Facilitator | Coinbase CDP (free tier: 1000 tx/month) | Tempo network |
| Client SDK | `@x402/fetch`, `@x402/evm` (viem) | `mppx` (wevm) |
| Server SDK | `@x402/express`, `@x402/hono`, `@x402/next` | `mppx/server` (Express, Hono, Next.js) |
| Gas handling | **Facilitator pays gas** (client gasless) | Client pays on Tempo |
| Ecosystem | Zerion, Alchemy, 30+ services on Base | 100+ services on Tempo |
| GitHub | `coinbase/x402` | `wevm/mppx`, `tempoxyz/mpp-specs` |
| Hackathon usage | Other Synthesis teams already use x402 on Base | Bounty lists MPP as a resource |

### 5.2 Recommendation: Dual-Protocol with x402 Primary

**Primary path: x402** — native Base support, Permit2 enables **any ERC-20 including wstETH**, facilitator handles gas, real services already accept it on Base.

**Secondary path: MPP custom method** — demonstrates MPP extensibility per the bounty's mention of mpp.dev. Self-hosted demo service only.

### 5.3 x402 Integration (Primary — Real Services)

#### How x402 Works

```
1. Agent: GET https://api.zerion.io/portfolio (or any x402 service)
2. Server: 402 Payment Required
   PAYMENT-REQUIRED: base64({scheme:"exact", network:"eip155:8453", amount:"1000",
     asset:"0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452", payTo:"0xSERVER"})

3. Agent: Claims yield from treasury → receives wstETH in agent wallet
4. Agent: Signs Permit2 authorization for wstETH transfer
   Retries with PAYMENT-SIGNATURE header

5. Facilitator: Broadcasts transfer on Base (pays gas)
6. Server: Returns 200 + data + PAYMENT-RESPONSE header
```

#### x402 with wstETH via Permit2

x402 supports **any ERC-20 on Base via Permit2**. wstETH on Base (`0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452`) is a standard ERC-20, so it should work with Permit2 after a one-time approval.

**One-time setup:** Agent approves the canonical Permit2 contract to spend wstETH.

**Per-request flow:**
1. Agent claims yield: `treasury.claimYield(amount, agentAddress)` — wstETH goes to agent wallet
2. Agent signs Permit2 witness for the x402 payment
3. x402 facilitator broadcasts the transfer (agent pays no gas)
4. Service receives wstETH and delivers content

#### x402 with USDC (Simpler Path)

Alternatively, the agent swaps yield wstETH → USDC first, then pays in USDC via EIP-3009:
1. Agent claims yield as wstETH
2. Agent swaps on Uniswap/Aerodrome (wstETH → USDC) on Base
3. Agent pays in USDC using x402 (EIP-3009, truly gasless)

#### Client Code (x402)

```typescript
import { wrapFetch } from '@x402/fetch'
import { ExactEvmScheme } from '@x402/evm/exact/client'
import { privateKeyToAccount } from 'viem/accounts'

const signer = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY as `0x${string}`)

const x402Fetch = wrapFetch(fetch, {
  schemes: [new ExactEvmScheme({ signer })],
})

// After claiming yield to agent wallet, make paid API calls:
const response = await x402Fetch('https://api.zerion.io/portfolio?address=0x...')
```

#### Server Code (x402 — Our Demo Service)

```typescript
import express from 'express'
import { paymentMiddleware } from '@x402/express'
import { ExactEvmScheme } from '@x402/evm/exact/server'
import { HTTPFacilitatorClient } from '@x402/core/server'

const app = express()
const facilitator = new HTTPFacilitatorClient({ url: 'https://x402.org/facilitator' })

app.use(paymentMiddleware({
  'GET /api/search': {
    accepts: [{
      scheme: 'exact',
      price: '$0.01',
      network: 'eip155:8453',  // Base mainnet
      payTo: SERVER_ADDRESS,
    }],
    description: 'Web search API',
  },
}))

app.get('/api/search', async (req, res) => {
  const results = await callUpstreamAPI(req.query.q)
  res.json(results)
})
```

### 5.4 MPP Integration (Secondary — Via Squid Bridge or Custom Method)

#### Why Include MPP

The bounty lists mpp.dev under Resources. Supporting MPP shows protocol versatility and demonstrates the AgentTreasury works with any 402-based payment system.

#### Tempo Chain & The Bridge Solution

**Tempo is its own blockchain (Chain ID 4217)**, not an Ethereum L2. It uses TIP-20 stablecoins (pathUSD). However, **Squid Router is live on Tempo** ([announcement](https://www.squidrouter.com/blog/squid-live-on-tempo-blockchain-payments)), enabling cross-chain bridging from 100+ chains (including Base) to Tempo's pathUSD.

This unlocks a **native MPP path**: bridge yield from Base → Tempo, then pay with MPP natively on Tempo using the 100+ MPP-enabled services.

#### Path A: Squid Bridge → Native Tempo MPP (Recommended for MPP)

```
Treasury (Base) → claimYield → Agent wallet (wstETH on Base)
    → Squid Router: swap wstETH (Base) → pathUSD (Tempo)
    → Agent uses mppx client with native tempo method
    → Pays for 100+ MPP services (Alchemy, Dune, Parallel, etc.)
```

**Squid SDK integration:**
```typescript
import { Squid } from '@0xsquid/sdk'

const squid = new Squid({
  baseUrl: 'https://v2.api.squidrouter.com',
  integratorId: 'steth-agent-treasury',
})
await squid.init()

// Bridge wstETH (Base) → pathUSD (Tempo)
const route = await squid.getRoute({
  fromAddress: agentAddress,
  fromChain: '8453',                    // Base
  fromToken: '0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452',  // wstETH on Base
  fromAmount: yieldAmount.toString(),
  toChain: '4217',                      // Tempo
  toToken: '0x20c0000000000000000000000000000000000000',      // pathUSD on Tempo
  toAddress: agentTempoAddress,
  slippage: 1.0,
})

// Execute the bridge
const tx = await squid.executeRoute({ signer, route: route.route })
```

After bridging, the agent has pathUSD on Tempo and can use standard `mppx` Tempo payments:
```typescript
import { Mppx, tempo } from 'mppx/client'

Mppx.create({
  methods: [tempo({ account: privateKeyToAccount(AGENT_KEY) })],
})

// Now fetch from any of 100+ MPP services natively
const response = await fetch('https://mpp.quickintel.io/api/scan')
```

#### Path B: Custom MPP Method on Base (Simpler, No Bridge)

For services we self-host, we can skip the bridge entirely with a custom MPP method:

#### Custom Method Definition

```typescript
import { Method, z } from 'mppx'

const wstethYield = Method.from({
  intent: 'charge',
  name: 'wsteth-yield',
  schema: {
    credential: {
      payload: z.object({ txHash: z.string() }),
    },
    request: z.object({
      amount: z.string(),
      currency: z.literal('wsteth'),
      recipient: z.string(),
      chainId: z.literal(8453),
    }),
  },
})
```

#### Client (Agent)

```typescript
import { Mppx } from 'mppx/client'

const clientMethod = wstethYield.toClient({
  pay: async ({ request }) => {
    const tx = await treasuryContract.write.claimYield([
      BigInt(request.amount), request.recipient,
    ])
    await publicClient.waitForTransactionReceipt({ hash: tx })
    return { txHash: tx }
  },
})

const mppx = Mppx.create({ methods: [clientMethod], polyfill: false })
const response = await mppx.fetch('https://demo-service.example.com/api/search?q=AI+trends')
```

#### Server (Demo Service)

```typescript
import { Mppx } from 'mppx/server'
import { Hono } from 'hono'

const serverMethod = wstethYield.toServer({
  verify: async ({ credential }) => {
    const receipt = await baseClient.getTransactionReceipt({ hash: credential.payload.txHash })
    // Parse Transfer event, verify amount >= requested, recipient matches
    return { valid: true, reference: credential.payload.txHash }
  },
})

const mppx = Mppx.create({ methods: [serverMethod] })
const app = new Hono()

app.get('/api/search',
  mppx.charge({ amount: '10000000000000', currency: 'wsteth', recipient: SERVER_ADDRESS, chainId: 8453 }),
  async (c) => {
    const results = await callUpstreamAPI(c.req.query('q'))
    return c.json(results)
  }
)
```

### 5.5 Token Flow (All Three Paths)

```
Treasury Contract (Base)
    │
    │ claimYield(amount, agentAddress)
    │ [wstETH transfer on Base]
    ▼
Agent Wallet (wstETH on Base)
    │
    ├─── PATH 1 — x402 (Base-native, real services)
    │    Permit2 sign → CDP facilitator broadcasts → service receives wstETH
    │    (or: swap to USDC → EIP-3009 → service receives USDC)
    │    Works with: Zerion, Alchemy, Quick Intel, self-hosted services
    │
    ├─── PATH 2 — MPP via Squid Bridge (native Tempo, 100+ services)
    │    Squid Router: wstETH (Base) → pathUSD (Tempo)
    │    → mppx tempo client → pay 100+ MPP services natively
    │    Works with: Alchemy, Dune, Parallel, Quick Intel, etc.
    │
    └─── PATH 3 — MPP Custom Method (Base-only, self-hosted)
         claimYield directly to server → tx hash as credential → server verifies
         Works with: our own demo service only
```

### 5.6 Real-World Dual-Protocol Precedent

**Quick Intel** ([mpp.quickintel.io](https://mpp.quickintel.io)) already accepts **both MPP and x402 simultaneously** on all paid endpoints, supporting Base, Ethereum, Arbitrum, Solana, and 11+ chains. This validates our dual-protocol approach.

**Zerion** launched x402 payments on Base on March 19, 2026 — AI agents pay 0.01 USDC per API call for portfolio data.

**Stripe bridges MPP to Base via x402** — they support both protocols as separate integration paths, per [CoinbaseDev](https://x.com/CoinbaseDev/status/2021358906480656621) and [Base official](https://x.com/base/status/2021413560740721048).

### 5.7 Recommended Demo Services

| Service | Protocol | What It Does | Cost |
|---------|----------|-------------|------|
| **Self-hosted search proxy** | x402 + MPP | Web search (Parallel/Exa) | ~$0.01/call |
| **Self-hosted image gen proxy** | x402 + MPP | fal.ai/StableStudio image gen | ~$0.02/call |
| **Zerion Portfolio API** | x402 (native) | Real Base service, portfolio data | ~$0.01/call |
| **Alchemy API** | x402 (native) | Blockchain data | ~$0.001/call |

### 5.7 Key npm Packages

```bash
# x402 (primary — Base-native payments)
npm install @x402/fetch @x402/evm @x402/core @x402/hono

# MPP (secondary — Tempo-native or custom method)
npm install mppx viem

# Squid Router (bridge Base wstETH → Tempo pathUSD for native MPP)
npm install @0xsquid/sdk

# Shared
npm install viem wagmi
```

---

## 6. Demo Plan

### 6.1 Demo Scenario: "The Self-Funding AI Research Assistant"

A startup gives its AI research agent an operating budget backed by stETH yield. The agent searches the web, generates images, and analyzes data — all paid for by staking rewards. The startup's $10,000 principal is never at risk.

### 6.2 Yield Feasibility

| Principal | Daily Yield (3.5% APR) | 30-Day Accumulation |
|-----------|----------------------|---------------------|
| $1,000 | $0.096 | $2.88 |
| **$10,000** | **$0.96** | **$28.77** |
| $50,000 | $4.79 | $143.84 |
| $100,000 | $9.59 | $287.67 |

**Strategy:** Deposit ~3.6 wstETH ($10,000) at least 3-4 weeks before the demo. This accumulates ~$25-30 in yield — enough for hundreds of cheap API calls ($0.001-0.01 each).

**No mocks required.** The yield is real, just small. The demo narrative emphasizes the structural separation (principal locked, yield spendable) rather than dollar amounts.

### 6.3 Step-by-Step Demo Script (5-7 minutes)

**Act 1 — Setup (1 min)**
- Show the dashboard. Principal = 3.6 wstETH ($10,000), locked with green lock icon.
- Yield Available = ~0.009 wstETH (~$25). Show it accruing in real-time.
- Show permission settings: 3 whitelisted service addresses, 0.002 wstETH per-tx cap, 0.01 wstETH daily limit.

**Act 2 — Agent Performs Tasks (2-3 min)**
1. Agent calls web search via x402 → dashboard shows -0.000004 wstETH. Search results displayed.
2. Agent calls LLM inference via x402 → dashboard shows -0.00002 wstETH. Summary displayed.
3. Agent calls image generation via MPP custom method → dashboard shows -0.00001 wstETH. Generated image displayed.
4. All transactions appear in activity log with green checkmarks. Both x402 and MPP receipts shown.

**Act 3 — Permission Enforcement (1-2 min)**
1. Agent tries to claim 0.003 wstETH → **REJECTED** (exceeds 0.002 per-tx cap). Red alert on dashboard.
2. Agent tries to send to non-whitelisted address → **REJECTED**. Red alert.
3. Show the contract code: no function the agent can call touches principal.
4. Owner clicks "Withdraw Principal" → succeeds. Only owner has this power.

**Act 4 — Summary (30 sec)**
- Principal still exactly 3.6 wstETH. Agent spent 0.000034 wstETH from yield.
- Contract verified on BaseScan. All transactions on-chain. No mocks.

### 6.4 Fallback Plans

| Risk | Fallback |
|------|----------|
| Yield too small to see | Pre-deposit 4+ weeks early; show absolute numbers rather than percentages |
| x402/MPP integration incomplete | Demo on-chain spending without protocol wrapper; fall back to direct claimYield() calls |
| Rate oracle stale | Update manually right before demo; oracle stores `lastUpdated` for transparency |
| Smart contract bug found late | Pre-deploy backup contract; have Foundry fork ready |

---

## 7. Technical Risks & Mitigations

### 7.1 Security Considerations

| Attack Vector | Severity | Mitigation |
|--------------|----------|------------|
| Reentrancy on yield claim | HIGH | `ReentrancyGuard` + CEI pattern; state updated before transfer |
| Share rate manipulation | LOW | `stEthPerToken()` is oracle-controlled (~daily), not manipulable in single tx |
| Front-running yield claims | LOW | Permissioned (only AGENT_ROLE); no price impact |
| Rounding exploits | MEDIUM | wstETH-only accounting (no stETH rounding dust); round DOWN for yield |
| Permission bypass via delegatecall | LOW | No delegatecall in contract; no generic execute function |
| Agent blocks owner withdrawal | LOW | `withdrawPrincipal()` has no dependency on agent state |
| Governance/upgrade attack | HIGH | Immutable deployment (no proxy) |
| Token approval exposure | MEDIUM | `SafeERC20.forceApprove()` for exact amounts only |
| Stale rate oracle | MEDIUM | `lastUpdated` timestamp exposed; agent/UI can warn if stale |
| Integer overflow | LOW | Solidity 0.8+ built-in checks; `Math.mulDiv` for safe multiplication |
| Flash loan attacks | N/A | Rate determined by Lido oracle, not DEX liquidity |
| Yield sandwiching | N/A | Single depositor; agent cannot deposit |

### 7.2 Yield Timing Issues

- **Lido oracle reports ~daily.** Yield accrues in discrete jumps, not continuously. Between reports, `stEthPerToken()` is constant.
- **Rate oracle on Base may lag L1.** Accept minutes-to-hours of staleness; for a hackathon demo, manual updates before the demo suffice.
- **Spending window resets** based on `block.timestamp`, which is reliable on Base.

### 7.3 L2-Specific Considerations

- **Base wstETH is `ERC20Bridged`** — standard ERC-20 transfers work normally, but no `wrap()`, `unwrap()`, or `stEthPerToken()`.
- **No stETH on Base** — yield can only be claimed as wstETH (not stETH). This simplifies the contract.
- **Sequencer downtime** — if Base sequencer goes down, agent cannot spend. Not a security risk, just a liveness issue.

### 7.4 Design Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| ERC-4626? | **No** | Unnecessary for single-depositor yield-splitting. Adds attack surface without benefit. |
| Internal accounting | **wstETH only** | Eliminates rebasing bugs and stETH rounding dust entirely |
| Access control | **OZ AccessControl** | Multi-role (Owner/Agent/Guardian), battle-tested |
| Upgradability | **None (immutable)** | Stronger trust guarantees for hackathon judges |
| Price feeds for caps | **Avoid** — caps in wstETH terms | No oracle dependency for permission enforcement |
| Yield tokenization | **No** — permission-based access | Dramatically simpler than Pendle-style PT/YT split |
| Custom errors | **Yes** | ~50 gas savings per revert, reduced deployment cost |
| Storage packing | **Yes** — permission vars packed | `uint128` caps + `uint64` timestamps in 2 slots |

---

## 8. Implementation Roadmap

### Phase 1: Core Contract (Day 1-2)

- [ ] `AgentTreasury.sol`: deposit, withdraw (owner only), yield calculation, claimYield (agent only)
- [ ] `RateOracle.sol`: owner-updatable rate source
- [ ] `IRateOracle.sol`, `IWstETH.sol` interfaces
- [ ] OpenZeppelin imports: AccessControl, ReentrancyGuard, SafeERC20, Pausable, Math
- [ ] Unit tests with Foundry (fork Base mainnet for real wstETH)
- [ ] Deploy to Base Sepolia testnet

### Phase 2: Permission System (Day 2-3)

- [ ] Recipient whitelist (add/remove)
- [ ] Per-transaction cap
- [ ] Time-windowed daily spending limit
- [ ] Cooldown period
- [ ] Events for all state changes
- [ ] Tests: blocked claims (over cap, non-whitelisted, cooldown) + allowed claims
- [ ] Invariant/fuzz tests: after any operation, `wstETH.balanceOf(this) >= principalWstETHFloor()`

### Phase 3: Agent Runtime (Day 3-4)

- [ ] Node.js agent with viem for Base contract interaction
- [ ] Query yield balance via `getAvailableYield()`
- [ ] Execute `claimYield()` with proper gas estimation
- [ ] Simple task orchestration: search → summarize → generate image
- [ ] Activity logging (stdout + file)

### Phase 4: Payment Protocol Integration (Day 4-5)

- [ ] **x402 (primary):** Install `@x402/fetch`, `@x402/evm`, `@x402/hono`
- [ ] x402 client: agent claims yield → Permit2 sign → pay for services
- [ ] x402 server: demo service with `paymentMiddleware` accepting wstETH on Base
- [ ] Test with real x402 services (Zerion, Alchemy) if they accept Permit2 tokens
- [ ] **MPP (secondary):** Custom `wsteth-yield` method via `mppx` `Method.from()`
- [ ] MPP client (`Method.toClient`) + server (`Method.toServer`)
- [ ] Integration test: full 402 → credential/signature → receipt flow for both protocols

### Phase 5: Frontend Dashboard (Day 5-6)

- [ ] Next.js 14+ with App Router
- [ ] viem + wagmi for wallet connection and contract reads
- [ ] Tailwind CSS + shadcn/ui components
- [ ] Principal card (locked amount, USD value)
- [ ] Yield card (available yield, accrual rate)
- [ ] Permissions panel (whitelist, caps, limits)
- [ ] Activity log (real-time via event polling)
- [ ] Owner actions: deposit, withdraw, edit permissions
- [ ] Agent status indicator

### Phase 6: Deploy & Polish (Day 6-7)

- [ ] Deploy to Base mainnet
- [ ] Deposit real wstETH ($10K+ worth)
- [ ] Update rate oracle with current `stEthPerToken()` from mainnet
- [ ] Verify all contracts on BaseScan
- [ ] Record backup demo video
- [ ] Write documentation and README
- [ ] Practice demo script

### Cut List (if time runs short)

| Feature | Priority | Reason to cut |
|---------|----------|---------------|
| Yield-over-time chart | Low | Numbers-only display works |
| Swap contract (wstETH → USDC) | Low | Pay in wstETH directly |
| Sub-agent allocation | Low | Stretch goal, not required by bounty |
| Time-windowed limits | Medium | Keep whitelist + per-tx cap (simpler) |
| MPP session mode | Low | Charge/one-time is sufficient |
| Factory contract | Low | Single treasury deployment is fine |
| Guardian role | Low | Owner + Agent covers bounty requirements |

---

## 9. Open Questions

### Decisions Needed

1. **Exact deposit amount and timing?** Recommend $10K+ deposited 3-4 weeks before demo. Need to decide exact amount based on budget.

2. **x402 vs MPP priority?** Recommend x402 as primary (native Base, Permit2 for any ERC-20, real ecosystem services). MPP as secondary demo showing protocol versatility. Or focus exclusively on x402 if time is tight.

3. **Payment token: wstETH via Permit2 or swap to USDC?** wstETH via Permit2 is more thematic (yield stays as wstETH). USDC via EIP-3009 is simpler and works with more existing services. Could demo both.

4. **Rate oracle update frequency?** Daily is sufficient for yield accuracy. Need a script or cron job to push L1 rate to Base oracle.

5. **Should the agent send wstETH directly to the server, or claim to its own wallet first then pay?** For x402: must claim to agent wallet first (agent signs Permit2). For MPP custom method: can claimYield directly to server (one tx).

6. **Frontend hosting?** Vercel (simplest for Next.js) or self-hosted?

### Things to Validate During Implementation

- [ ] **CRITICAL: Test wstETH with x402 Permit2 on Base** — confirm ERC20Bridged token works with canonical Permit2 contract
- [ ] Test x402 facilitator at `https://x402.org/facilitator` with Base mainnet (not just testnet)
- [ ] Confirm `mppx` SDK's `Method.from()` works with custom on-chain verification
- [ ] Test wstETH transfer gas costs on Base (expect ~$0.002-0.005)
- [ ] Verify Foundry fork testing works with Base wstETH bridged token
- [ ] Confirm `wagmi` can read from custom contract on Base without issues
- [ ] Test rate oracle accuracy: push mainnet `stEthPerToken()`, verify yield calculation matches expected
- [ ] Check if existing x402 services on Base (Zerion, Alchemy) accept wstETH via Permit2 or only USDC
- [ ] Check if Lido has a Holesky/Sepolia testnet deployment on Base for development

### Competitive Analysis

- Bounty says "not looking for multisigs with a staking deposit bolted on" — our design is a purpose-built yield-splitting primitive, not a modified multisig
- "Strong entries show a working demo where an agent pays for something" — x402 integration with real Base services directly addresses this
- Permission system (whitelist + cap + time window) exceeds the "at least one configurable permission" requirement
- **x402 advantage**: agent pays for real services (Zerion, Alchemy) on Base using yield-claimed wstETH — not just our own demo service
- **MPP advantage**: custom payment method demonstrates protocol extensibility, aligns with bounty's mention of mpp.dev
- **Dual-protocol approach** shows the AgentTreasury works with any 402-based payment system — protocol-agnostic design
- Another hackathon team (`clawlinker/synthesis-hackathon`) uses x402 on Base for their "Molttail" audit trail project — validates x402 as the practical Base payment standard

---

## Appendix A: Required Interfaces

```solidity
interface IRateOracle {
    function getRate() external view returns (uint256);
}

interface IWstETH is IERC20 {
    // Only available on mainnet, NOT on L2 bridged versions:
    // function stEthPerToken() external view returns (uint256);
    // function wrap(uint256) external returns (uint256);
    // function unwrap(uint256) external returns (uint256);
    // function getStETHByWstETH(uint256) external view returns (uint256);
    // function getWstETHByStETH(uint256) external view returns (uint256);
}
```

## Appendix B: Contract Addresses

| Contract | Chain | Address |
|----------|-------|---------|
| wstETH | Base | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` |
| wstETH | Ethereum | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| wstETH | Arbitrum | `0x5979D7b546E38E414F7E9822514be443A4800529` |
| wstETH | Optimism | `0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb` |
| stETH | Ethereum | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |

## Appendix C: OpenZeppelin Contracts

| Contract | Import Path | Purpose |
|----------|-------------|---------|
| AccessControl | `@openzeppelin/contracts/access/AccessControl.sol` | Role-based permissions |
| ReentrancyGuard | `@openzeppelin/contracts/utils/ReentrancyGuard.sol` | Reentrancy protection |
| SafeERC20 | `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol` | Safe token transfers |
| Pausable | `@openzeppelin/contracts/utils/Pausable.sol` | Emergency circuit breaker |
| Math | `@openzeppelin/contracts/utils/math/Math.sol` | Safe mulDiv |

## Appendix D: Custom Errors

```solidity
error NotAuthorized();
error RecipientNotWhitelisted(address recipient);
error ExceedsAvailableYield(uint256 requested, uint256 available);
error ExceedsPerTransactionCap(uint256 requested, uint256 cap);
error ExceedsSpendingWindowLimit(uint256 requested, uint256 remaining);
error CooldownNotElapsed(uint256 nextAllowedTimestamp);
error PrincipalViolation(uint256 remainingBalance, uint256 requiredMinimum);
error InvalidRate();
error ZeroAmount();
error ZeroAddress();
```

## Appendix E: Gas Estimates (Base)

| Operation | Estimated Gas | Estimated Cost (Base) |
|-----------|--------------|----------------------|
| `deposit()` | ~80,000 | ~$0.04 |
| `claimYield()` | ~65,000 | ~$0.03 |
| `getAvailableYield()` | ~10,000 | Free (view) |
| `addRecipient()` | ~45,000 | ~$0.02 |
| `withdrawPrincipal()` | ~55,000 | ~$0.03 |
| wstETH transfer (ERC-20) | ~50,000 | ~$0.02 |
