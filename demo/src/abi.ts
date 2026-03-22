export const agentTreasuryAbi = [
  {
    type: "function",
    name: "getAvailableYield",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getStatus",
    inputs: [],
    outputs: [
      {
        name: "s",
        type: "tuple",
        components: [
          { name: "availableYield", type: "uint256" },
          { name: "availableYieldStETH", type: "uint256" },
          { name: "principalValueStETH", type: "uint256" },
          { name: "principalFloor", type: "uint256" },
          { name: "contractBalance", type: "uint256" },
          { name: "currentRate", type: "uint256" },
          { name: "maxPerTx", type: "uint128" },
          { name: "isPaused", type: "bool" },
        ],
      },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "claimYield",
    inputs: [
      { name: "amount", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "wstETHDeposited",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

export const erc20Abi = [
  {
    type: "event",
    name: "Transfer",
    inputs: [
      { name: "from", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "value", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;
