import dotenv from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: resolve(__dirname, "../../.env") });

// Base mainnet wstETH
export const WSTETH_ADDRESS = "0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452" as const;

// Keys & addresses from .env (with Anvil defaults for local fork testing)
export const AGENT_KEY = (process.env.AGENT_PRIVATE_KEY ||
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d") as `0x${string}`;

export const SERVER_ADDRESS = (process.env.SERVER_ADDRESS ||
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC") as `0x${string}`;

// Environment
export const RPC_URL = process.env.RPC_URL || process.env.BASE_RPC_URL || "http://127.0.0.1:8545";
export const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY || "";
export const TREASURY_ADDRESS = (process.env.TREASURY_ADDRESS) as `0x${string}`;

// Pricing: wstETH wei per API call
// 0.00001 wstETH ≈ $0.026 at ~$2,637/wstETH
export const PRICE_PER_CALL = 10_000_000_000_000n; // 1e13 wei = 0.00001 wstETH

export const SERVER_PORT = 3001;

// Default model for demo
export const DEFAULT_MODEL = "openai/gpt-4.1-nano";

// Chain ID: Base mainnet = 8453, Anvil fork = 31337
export const CHAIN_ID = RPC_URL.includes("127.0.0.1") || RPC_URL.includes("localhost") ? 31337 : 8453;
