# Team Research & PRD Prompt: stETH Agent Treasury

## Objective

Spawn a team of specialized agents to research from first principles and produce a detailed PRD for the **stETH Agent Treasury** hackathon bounty. The PRD must cover smart contract requirements, demo strategy, chain selection, and MPP (Machine Payments Protocol) integration so an AI agent can pay for real services using only staking yield.

---

## Bounty Summary

Build a contract primitive that lets a human give an AI agent a yield-bearing operating budget backed by stETH, without ever giving the agent access to the principal. Use wstETH as the yield-bearing asset. Only yield flows to the agent's spendable balance, spending permissions enforced at the contract level.

**Prize:** $2,000 (1st) + $1,000 (2nd)

**Must demonstrate:**
- Principal structurally inaccessible to the agent
- A spendable yield balance the agent can query and draw from
- At least one configurable permission (recipient whitelist, per-tx cap, or time window)
- Any L2 or mainnet accepted, no mocks

**Strong entries:** Working demo where an agent pays for something from its yield balance without touching principal.

---

## Agent Team Structure

Launch these agents **in parallel**. Each agent writes its findings to a dedicated section. After all agents complete, a synthesizer agent combines everything into the final PRD.

### Agent 1: Smart Contract Architect

**Role:** Design the on-chain architecture for the stETH Agent Treasury contract.

**Research tasks:**
1. Deeply understand wstETH mechanics — how yield accrues via share rate appreciation (NOT rebasing like stETH). wstETH balance stays constant; value grows as `stEthPerToken()` increases over time.
2. Design the yield calculation mechanism: `yieldAccrued = currentWstETHValue - depositTimeWstETHValue` in stETH terms. The contract must track the wstETH share rate at deposit time to compute how much yield has accrued.
3. Define the principal isolation model — the agent role can NEVER withdraw or transfer the deposited wstETH principal. Only the owner (human) can withdraw principal.
4. Design the permission system: recipient whitelist, per-transaction cap, time-windowed spending limits.
5. Consider: should yield be claimed as stETH, wstETH, or swapped to a stablecoin (e.g. USDC) for spending? For MPP integration, the agent likely needs a specific token.
6. Think about sub-agent yield allocation (parent agent splits yield budget among child agents).
7. Consider gas efficiency, reentrancy protection, upgradability (or deliberate immutability for trust).
8. Produce a complete list of contract functions, roles, events, and storage layout.

**Key technical context (already researched):**

**wstETH mechanics:**
- wstETH is a non-rebasing ERC-20 wrapper for stETH. Balance stays constant; value grows via share rate.
- `stEthPerToken()` — returns how much stETH one wstETH is worth (increases over time as yield accrues)
- `getStETHByWstETH(amount)` — converts wstETH amount to stETH equivalent
- `wrap(stETHAmount)` — wraps stETH into wstETH (requires prior stETH approval)
- `unwrap(wstETHAmount)` — unwraps wstETH back to stETH
- `receive()` — accepts raw ETH, stakes it, and auto-wraps to wstETH
- Implements ERC-20, ERC-2612 (permit), EIP-712
- Mainnet wstETH: `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
- Mainnet stETH: `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`

**Yield calculation approach:**
- At deposit time, record `initialStEthPerToken = wstETH.stEthPerToken()`
- At any point, `currentStEthPerToken = wstETH.stEthPerToken()`
- Yield in stETH terms = `wstETHDeposited * (currentStEthPerToken - initialStEthPerToken) / 1e18`
- This yield amount can be unwrapped from the wstETH pool and given to the agent
- BUT: unwrapping yield means converting some wstETH to stETH, which reduces the wstETH balance. The contract must ensure the remaining wstETH still covers the original principal in stETH-equivalent terms.

**stETH rebasing details:**
- stETH rebases daily when Lido oracle reports. 9 oracles, 5+ quorum needed.
- Internally uses shares: `shares[account] = balanceOf(account) * totalShares / totalPooledEther`
- 1-2 wei rounding dust on transfers due to integer division
- Lido takes 10% fee on rewards (5% node operators, 5% treasury)
- Current APR ~3-4% annually

**Sources to research further:**
- stETH/wstETH integration guide: https://docs.lido.fi/guides/lido-tokens-integration-guide
- wstETH contract docs: https://docs.lido.fi/contracts/wsteth
- Deployed contracts (all chains): https://docs.lido.fi/deployed-contracts
- Lido JS SDK: https://github.com/lidofinance/lido-ethereum-sdk
- Look at existing DeFi vault patterns (ERC-4626, yield splitter contracts) for inspiration
- Research how other projects have separated principal from yield on-chain

---

### Agent 2: MPP (Machine Payments Protocol) Research Specialist

**Role:** Deep-dive into MPP to understand how an AI agent can pay for services, specifically using Tempo blockchain payments, and how to make this work on an EVM chain where wstETH exists.

**Research tasks:**
1. Understand the full MPP payment flow: HTTP 402 challenge → credential → receipt cycle
2. Research Tempo stablecoins as a payment method — what chain does Tempo run on? What tokens does it use?
3. **Critical question:** Can Tempo contracts be deployed to other EVM chains (Base, Arbitrum, Optimism, Ethereum mainnet)? The bounty requires wstETH on a real chain, so we need MPP/Tempo to work on a chain where wstETH is deployed.
4. If Tempo is its own chain, research bridging options: can the agent's yield be bridged to Tempo for payments? Or can a Tempo payment channel be opened on an EVM L2?
5. Research alternative MPP payment methods that might work on EVM chains where wstETH exists (Stripe as fallback? Custom payment method?)
6. Understand the `mppx` TypeScript SDK — client-side usage for agents to automatically handle 402 payment flows
7. Research how to set up an MPP-enabled service (server-side) that the agent will pay for in the demo
8. Determine the minimum viable MPP integration for the hackathon demo

**Key context (already researched):**

**MPP overview:**
- Open standard for machine-to-machine payments via HTTP 402
- Co-developed by Tempo and Stripe
- Challenge-credential-receipt flow embedded in HTTP headers
- Supports: Tempo stablecoins, Stripe cards, Lightning Bitcoin, custom methods
- "Payment-method agnostic" — anyone can author new payment methods
- Session-based payments enable sub-100ms latency via off-chain vouchers
- Supports one-time charges, streaming payments (SSE), pay-as-you-go metering
- IETF draft: draft-httpauth-payment
- SDKs: TypeScript (mppx), Python (pympp), Rust (mpp)
- Server middleware: Express, Hono, Next.js, Elysia

**Sources — ALL of these must be researched (the docs site is client-rendered so use browser or llms.txt):**
- Main site: https://mpp.dev
- LLM-friendly docs: https://mpp.dev/llms.txt and https://mpp.dev/llms-full.txt
- Tempo payment method: https://mpp.dev/payment-methods/tempo/
- Tempo charge: https://mpp.dev/payment-methods/tempo/charge
- Tempo session: https://mpp.dev/payment-methods/tempo/session
- Custom payment methods: https://mpp.dev/payment-methods/custom
- Agent quickstart: https://mpp.dev/quickstart/agent
- Client quickstart: https://mpp.dev/quickstart/client
- Server quickstart: https://mpp.dev/quickstart/server
- Building with LLMs guide: https://mpp.dev/guides/building-with-an-llm
- One-time payments: https://mpp.dev/guides/one-time-payments
- Pay-as-you-go: https://mpp.dev/guides/pay-as-you-go
- Streamed payments: https://mpp.dev/guides/streamed-payments
- Multiple payment methods: https://mpp.dev/guides/multiple-payment-methods
- Protocol challenges: https://mpp.dev/protocol/challenges
- Protocol credentials: https://mpp.dev/protocol/credentials
- Protocol receipts: https://mpp.dev/protocol/receipts
- HTTP 402: https://mpp.dev/protocol/http-402
- HTTP transport: https://mpp.dev/protocol/transports/http
- MCP transport: https://mpp.dev/protocol/transports/mcp
- TypeScript SDK overview: https://mpp.dev/sdk/typescript/
- TS client Method.tempo: https://mpp.dev/sdk/typescript/client/Method.tempo
- TS client Method.tempo.charge: https://mpp.dev/sdk/typescript/client/Method.tempo.charge
- TS client Method.tempo.session: https://mpp.dev/sdk/typescript/client/Method.tempo.session
- TS client Mppx.create: https://mpp.dev/sdk/typescript/client/Mppx.create
- TS server Method.tempo: https://mpp.dev/sdk/typescript/server/Method.tempo
- TS server Method.tempo.charge: https://mpp.dev/sdk/typescript/server/Method.tempo.charge
- TS server Method.tempo.session: https://mpp.dev/sdk/typescript/server/Method.tempo.session
- TS server Mppx.create: https://mpp.dev/sdk/typescript/server/Mppx.create
- FAQ: https://mpp.dev/faq
- Python SDK: https://mpp.dev/sdk/python/
- Rust SDK: https://mpp.dev/sdk/rust/

**NOTE:** The mpp.dev docs are client-side rendered (Vocs framework). Standard fetch may return only CSS. Agents should use `https://mpp.dev/llms.txt` and `https://mpp.dev/llms-full.txt` as primary sources, or use browser-based tools if available.

---

### Agent 3: Product & Demo Strategist

**Role:** Design the demo experience, select the target chain, plan what the agent actually does in the demo, and how all pieces connect.

**Research tasks:**
1. **Chain selection** — Pick ONE chain for the demo based on:
   - wstETH must be deployed there (see addresses below)
   - MPP/Tempo must be usable there (or we deploy custom payment method)
   - Gas costs should be low for demo
   - Good tooling/RPC availability
   - Candidates: Base, Arbitrum, Optimism, Ethereum mainnet, Scroll, Polygon
2. **Yield feasibility for demo** — Current Lido APR is ~3-4%. Calculate:
   - How much ETH/wstETH do we need to stake to generate meaningful yield for a demo?
   - Example: $10,000 staked at 3.5% APR = $350/year = ~$0.96/day. Is that enough for a few API calls?
   - If yield is too small for a live demo, consider: (a) using a larger stake amount, (b) simulating time passage via fork testing, (c) pre-accumulating yield before demo day
3. **Demo scenario design** — What does the agent actually DO? Ideas:
   - Agent calls an MPP-protected API (e.g., LLM inference, image generation, web search) and pays from yield
   - Show the dashboard: principal locked, yield accruing, agent spending from yield only
   - Show permission controls: agent tries to overspend → blocked; agent pays whitelisted recipient → succeeds
4. **End-to-end flow** for the demo:
   - Human deposits wstETH into Agent Treasury contract
   - Sets permissions (whitelist, caps)
   - Agent queries available yield balance
   - Agent calls MPP-protected service
   - Payment goes through from yield
   - Principal remains untouched
5. **Frontend/UI** — What do we need to show? Dashboard showing principal, yield, spending history, permissions?
6. **Additional contracts needed** — Do we need a swap contract (wstETH yield → USDC for payments)? A payment router?

**wstETH deployed addresses:**
- Ethereum: `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
- Arbitrum: `0x5979D7b546E38E414F7E9822514be443A4800529`
- Optimism: `0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb`
- Base: `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452`
- Polygon: `0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD`
- zkSync: `0x703b52F2b28fEbcB60E1372858AF5b18849FE867`
- Scroll: `0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32`
- Linea: `0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F`
- Mantle: `0x458ed78EB972a369799fb278c0243b25e5242A83`

**Sources:**
- Lido deployed contracts: https://docs.lido.fi/deployed-contracts
- Hackathon bounty details: see bounty summary above
- MPP site for supported chains: https://mpp.dev
- Research gas costs on candidate chains
- Check DEX liquidity for wstETH→stablecoin swaps on candidate chains

---

### Agent 4: Smart Contract Security & Patterns Researcher

**Role:** Research existing patterns, potential vulnerabilities, and best practices for yield-splitting vault contracts.

**Research tasks:**
1. Research ERC-4626 tokenized vault standard — can we use or extend it?
2. Look at existing yield-splitting protocols (e.g., Pendle, Spectra, Element Finance) for architectural inspiration
3. Research access control patterns: OpenZeppelin AccessControl vs custom roles
4. Identify attack vectors: reentrancy on yield claim, share rate manipulation, front-running yield claims, rounding exploits
5. Research how to handle the "1-2 wei rounding dust" issue from stETH transfers
6. Consider: should the contract hold wstETH and unwrap yield to stETH for spending? Or keep everything in wstETH terms?
7. Research Chainlink price feeds for wstETH/stETH on various L2s (needed if we add USD-denominated spending caps)
8. Research OpenZeppelin contracts we should use: ReentrancyGuard, Ownable, AccessControl, SafeERC20

**Sources:**
- ERC-4626: https://eips.ethereum.org/EIPS/eip-4626
- OpenZeppelin contracts: https://docs.openzeppelin.com/contracts
- Lido integration guide (rounding/drift): https://docs.lido.fi/guides/lido-tokens-integration-guide
- Search for existing yield-splitting vault implementations on GitHub

---

## Expected Output: PRD Document

After all agents complete their research, synthesize findings into a PRD at `lido/lido_steth_agent_treasury/PRD.md` with these sections:

### 1. Executive Summary
- What we're building, why it matters, target bounty

### 2. Architecture Overview
- System diagram: contracts, agent, MPP service, frontend
- Chain selection decision with justification

### 3. Smart Contract Specification
- Contract name, inheritance, roles
- Complete function list with signatures, access control, and descriptions
- Storage layout
- Events
- Permission system design
- Yield calculation mechanism (with formulas)
- Principal isolation guarantees

### 4. Additional Contracts
- Any helper contracts needed (swap router, payment adapter, etc.)
- MPP integration contracts if needed

### 5. MPP Integration Plan
- How the agent pays for services using yield
- Tempo/custom payment method on chosen chain
- Token flow: wstETH yield → [swap?] → payment token → MPP service
- SDK integration details

### 6. Demo Plan
- Step-by-step demo script
- What the audience sees
- Yield feasibility calculation
- Fallback plans if live yield is insufficient

### 7. Technical Risks & Mitigations
- Security considerations
- Yield timing issues
- Cross-chain complexities

### 8. Implementation Roadmap
- Phase 1: Core contract
- Phase 2: Agent integration
- Phase 3: MPP payments
- Phase 4: Demo & frontend

### 9. Open Questions
- Decisions still needed
- Things to validate during implementation

Use Claude for Chrome for web search/read if needed
