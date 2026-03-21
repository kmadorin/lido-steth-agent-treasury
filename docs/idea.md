# stETH Agent Treasury

## Bounty: $3,000

Build a contract primitive that lets a human give an AI agent a yield-bearing operating budget backed by stETH, without ever giving the agent access to the principal. Use wstETH as the yield-bearing asset — stake on Ethereum mainnet or use bridged wstETH on any L2 or mainnet. Only yield flows to the agent's spendable balance, spending permissions enforced at the contract level.

## Requirements

Must demonstrate at minimum:
- Principal structurally inaccessible to the agent
- A spendable yield balance the agent can query and draw from
- At least one configurable permission (recipient whitelist, per-transaction cap, or time window)
- Any L2 or mainnet accepted, no mocks

## What Wins

Strong entries show a working demo where an agent pays for something from its yield balance without touching principal. Not looking for multisigs with a staking deposit bolted on.

## Target Use Cases

- An agent pays for API calls and compute from its yield balance without ever touching principal
- A team gives their autonomous agent a monthly dollar budget funded entirely by staking rewards
- A multi-agent system where a parent agent allocates yield budgets to sub-agents

## Resources

- stETH integration guide (rebasing drift is the key section): https://docs.lido.fi/guides/steth-integration-guide
- wstETH contract: https://docs.lido.fi/contracts/wsteth
- Contract addresses: https://docs.lido.fi/deployed-contracts
- Lido JS SDK: https://github.com/lidofinance/lido-ethereum-sdk
- Machine payments protocol: https://mpp.dev

## Prizes

- **1st Place ($2,000):** Best contract primitive enabling AI agents to spend stETH yield without accessing principal, with enforced permission controls and a working demo.
- **2nd Place ($1,000):** Runner-up stETH agent treasury primitive with solid on-chain design and yield-only spending enforcement.
