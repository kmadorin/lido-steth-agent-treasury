# stETH Agent Treasury

A Solidity contract primitive that lets a human give an AI agent a yield-bearing operating budget backed by wstETH, without ever giving the agent access to the principal. Only staking yield flows to the agent's spendable balance, with spending permissions enforced at the contract level.

Built for the [Synthesis Hackathon](https://synthesis.md) — Lido stETH Agent Treasury bounty ($3,000).

## Deployed Contracts

| Contract | Chain | Address | Explorer |
|----------|-------|---------|----------|
| **AgentTreasury** | Base (8453) | `0x6DE964cD52cedb8D8FbD9BFE4c07f35c3cc9c1Ea` | [BaseScan](https://basescan.org/address/0x6DE964cD52cedb8D8FbD9BFE4c07f35c3cc9c1Ea) \| [Blockscout](https://base.blockscout.com/address/0x6DE964cD52cedb8D8FbD9BFE4c07f35c3cc9c1Ea) |
| wstETH (Base) | Base (8453) | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` | [BaseScan](https://basescan.org/address/0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452) |
| Chainlink wstETH/stETH Feed | Base (8453) | `0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061` | [BaseScan](https://basescan.org/address/0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061) |

**Roles:**
- Owner: `0x9F18653E6a6A1a839AFDe51f9e6b21cD888ee185`
- Agent: `0xD49d5290C81a921C324C1443032209050Ca84614`

**Verified:** Sourcify (exact match)

## How It Works

```
Human (Owner)                    AgentTreasury.sol                    AI Agent
     |                                |                                  |
     |-- deposit(wstETH) ------------>|                                  |
     |-- addRecipient(server) ------->|                                  |
     |-- setMaxPerTransaction(cap) -->|                                  |
     |                                |                                  |
     |                                |<-- getAvailableYield() ----------|
     |                                |<-- claimYield(amt, server) ------|
     |                                |                                  |
     |                                |   Principal LOCKED               |
     |                                |   Only yield is spendable        |
     |                                |   Post-condition: balance >= floor|
```

**Yield formula:** `Y = W * (Rt - R0) / Rt` where W = principal, R0 = rate at deposit, Rt = current rate.

**Principal isolation:** The agent can only call `claimYield()`, which is mathematically bounded by the yield formula. A post-condition check ensures `wstETH.balanceOf(this) >= principalFloor` after every claim.

## Features

- Principal structurally inaccessible to the agent (role-based + math-bounded + post-condition floor)
- Spendable yield balance queryable via `getAvailableYield()` and `getStatus()`
- Configurable permissions: recipient whitelist, per-transaction cap
- `topUpYield()` for owner to inject additional spending budget
- Chainlink oracle for wstETH/stETH rate (no mocks)
- Emergency pause (owner can pause claims; withdrawals always work)
- Non-upgradeable (immutable deployment for trust)

## MPP Demo — Agent Pays for AI with Yield

The `demo/` directory contains a working demo where an AI agent pays for OpenRouter model inference using only staking yield, via the Machine Payments Protocol (HTTP 402):

```
AI Agent --> POST /v1/chat/completions --> MPP Demo Service
         <-- 402 Payment Required        (Hono server)
         --> claimYield(amt, server)       |
         --> Retry with tx hash            |
         <-- 200 + AI response    <-- OpenRouter API
```

### Run the demo

```bash
# 1. Set up .env in project root
OPENROUTER_API_KEY=sk-or-v1-...

# 2. One-command demo (starts Anvil fork, deploys, funds, runs service + agent)
cd demo && ./run-demo.sh "What are the top 3 DeFi protocols?"
```

### Demo output

```
Treasury Status (Before):  0.1 wstETH yield, 10 wstETH principal
Agent pays:                0.00001 wstETH via claimYield()
AI Response:               [real response from OpenRouter]
Treasury Status (After):   0.09999 wstETH yield, 10 wstETH principal
Principal unchanged:       YES
```

## Test Suite

49 tests on Base mainnet fork (including 3 fuzz tests with 1000 runs each):

```bash
source .env && forge test --fork-url "$BASE_RPC_URL" -vv
```

Covers: deposit, withdraw, yield calculation, claim, top-up, admin permissions, edge cases (oracle failure, slashing recovery, reanchor), and principal floor invariant.

## Build & Deploy

```bash
# Build
forge build

# Test
source .env && forge test --fork-url "$BASE_RPC_URL" -vv

# Deploy to Base mainnet
source .env && forge script script/DeployAll.s.sol \
  --rpc-url https://mainnet.base.org \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast --verify
```

## Project Structure

```
src/AgentTreasury.sol          -- Yield-splitting vault (314 lines)
test/AgentTreasury.t.sol       -- 49 tests on Base fork
script/DeployAll.s.sol         -- Mainnet deployment
script/SetupDemo.s.sol         -- Anvil fork demo setup
demo/
  src/server.ts                -- MPP demo service (Hono, HTTP 402)
  src/agent.ts                 -- AI agent (yield -> payment -> AI response)
  src/verify.ts                -- On-chain payment verification
  run-demo.sh                  -- One-command demo launcher
```

## Resources

- [Lido stETH Integration Guide](https://docs.lido.fi/guides/steth-integration-guide)
- [wstETH Contract Docs](https://docs.lido.fi/contracts/wsteth)
- [Machine Payments Protocol](https://mpp.dev)
- [OpenRouter API](https://openrouter.ai/docs)
