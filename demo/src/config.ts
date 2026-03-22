import dotenv from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: resolve(__dirname, "../../.env") });

// Base mainnet wstETH
export const WSTETH_ADDRESS = "0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452" as const;

// Anvil default accounts (public Hardhat test keys — safe to hardcode)
export const OWNER_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
export const AGENT_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
export const SERVER_KEY =
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as const;

export const OWNER_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const;
export const AGENT_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const;
export const SERVER_ADDRESS = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const;

// Environment
export const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
export const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY || "";
export const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS as `0x${string}`;

// Pricing: wstETH wei per API call
// 0.00001 wstETH ≈ $0.026 at ~$2,637/wstETH
export const PRICE_PER_CALL = 10_000_000_000_000n; // 1e13 wei = 0.00001 wstETH

export const SERVER_PORT = 3001;

// Default model for demo
export const DEFAULT_MODEL = "openai/gpt-4.1-nano";
