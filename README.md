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
- Owner: [`0x9F18653E6a6A1a839AFDe51f9e6b21cD888ee185`](https://base.blockscout.com/address/0x9F18653E6a6A1a839AFDe51f9e6b21cD888ee185)
- Agent: [`0xD49d5290C81a921C324C1443032209050Ca84614`](https://base.blockscout.com/address/0xD49d5290C81a921C324C1443032209050Ca84614)
- Server (payment receiver): [`0x04f3D489938e9F642Fa474e6C8C353e46FA3Ae50`](https://base.blockscout.com/address/0x04f3D489938e9F642Fa474e6C8C353e46FA3Ae50) — whitelisted recipient

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

### Live Base Mainnet Example

Real on-chain interaction — agent paid for an AI API call using staking yield on Base mainnet:

```
╔══════════════════════════════════════════════════════╗
║   stETH Agent Treasury — MPP Demo Agent             ║
║   Paying for AI with staking yield                  ║
╚══════════════════════════════════════════════════════╝

Agent wallet: 0xD49d5290C81a921C324C1443032209050Ca84614
Treasury:     0x6DE964cD52cedb8D8FbD9BFE4c07f35c3cc9c1Ea

── Treasury Status (Before) ──
  Available yield:    0.000795607346949846 wstETH
  Principal (stETH):  0.000978596022459146 stETH
  Contract balance:   0.001591214693899691 wstETH

[Agent] Prompt: "What is wstETH and how does Lido staking yield work?"

[Agent] Requesting: POST http://localhost:3001/v1/chat/completions
[Agent] Got 402 — payment required: 0.00001 wstETH to 0x04f3D489...
[Agent] Claiming yield from treasury...
[Agent] Payment tx: 0x07c94d4f47be0a22e2eeeab0777cb4e2c9ce6a2220da5717f145274174bef449
[Agent] Confirmed in block 43719167 (status: success)
[Agent] Retrying with payment credential...
[Agent] Payment receipt: method="wsteth-yield", reference="0x07c94d4f..."

── AI Response ──
wstETH (Wrapped staked Ether) is a token that represents staked ETH
(via Lido) in a tradable, ERC-20 format. When you stake ETH through
Lido, you receive wstETH, which accrues staking rewards automatically.

── Treasury Status (After) ──
  Available yield:    0.000785607346949846 wstETH
  Principal (stETH):  0.000978596022459146 stETH

── Summary ──
  Yield spent:        0.00001 wstETH
  Principal unchanged: YES
```

**On-chain proof (Base mainnet):**
- Payment tx (claimYield): [`0x07c94d4f...`](https://basescan.org/tx/0x07c94d4f47be0a22e2eeeab0777cb4e2c9ce6a2220da5717f145274174bef449) | [Blockscout](https://base.blockscout.com/tx/0x07c94d4f47be0a22e2eeeab0777cb4e2c9ce6a2220da5717f145274174bef449)
- Deposit tx: [`0x2ec4eede...`](https://basescan.org/tx/0x2ec4eede7c8d87c2c113354188f107b32359d31239c614eb1604cffb6ee2f4b7) | [Blockscout](https://base.blockscout.com/tx/0x2ec4eede7c8d87c2c113354188f107b32359d31239c614eb1604cffb6ee2f4b7)
- TopUpYield tx: [`0x9112b6de...`](https://basescan.org/tx/0x9112b6dee703d46197ecaa7942205e6615b853d75d944b381cba4960e8a86cab) | [Blockscout](https://base.blockscout.com/tx/0x9112b6dee703d46197ecaa7942205e6615b853d75d944b381cba4960e8a86cab)
- Whitelist server tx: [`0xc5c8f110...`](https://basescan.org/tx/0xc5c8f1108e0f06165f7f158d74cd51b570b9ee762e290c81071653bdba446543) | [Blockscout](https://base.blockscout.com/tx/0xc5c8f1108e0f06165f7f158d74cd51b570b9ee762e290c81071653bdba446543)

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
