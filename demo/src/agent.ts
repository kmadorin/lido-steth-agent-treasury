import {
  createPublicClient,
  createWalletClient,
  http,
  formatEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { agentTreasuryAbi } from "./abi.js";
import {
  RPC_URL,
  AGENT_KEY,
  SERVER_ADDRESS,
  TREASURY_ADDRESS,
  DEFAULT_MODEL,
  SERVER_PORT,
} from "./config.js";

// ─── Setup ───────────────────────────────────────────────

const chain = { ...base, id: 31337 }; // Anvil fork
const transport = http(RPC_URL);
const account = privateKeyToAccount(AGENT_KEY);

const publicClient = createPublicClient({ chain, transport });
const walletClient = createWalletClient({ chain, transport, account });

const treasuryAddress = TREASURY_ADDRESS;
const serviceUrl = `http://localhost:${SERVER_PORT}/v1/chat/completions`;

// ─── Helpers ─────────────────────────────────────────────

async function getStatus() {
  const status = await publicClient.readContract({
    address: treasuryAddress,
    abi: agentTreasuryAbi,
    functionName: "getStatus",
  });
  return status;
}

function printStatus(label: string, status: any) {
  console.log(`\n── ${label} ──`);
  console.log(`  Available yield:    ${formatEther(status.availableYield)} wstETH`);
  console.log(`  Principal (stETH):  ${formatEther(status.principalValueStETH)} stETH`);
  console.log(`  Contract balance:   ${formatEther(status.contractBalance)} wstETH`);
  console.log(`  Max per tx:         ${formatEther(status.maxPerTx)} wstETH`);
  console.log(`  Paused:             ${status.isPaused}`);
}

/**
 * Make a paid API call to the MPP demo service.
 * Handles the HTTP 402 challenge → on-chain payment → retry flow.
 */
async function paidApiCall(
  prompt: string,
  model: string = DEFAULT_MODEL
): Promise<string> {
  const body = {
    model,
    messages: [{ role: "user", content: prompt }],
  };

  // ── Step 1: Initial request (expect 402) ──
  console.log(`\n[Agent] Requesting: POST ${serviceUrl}`);
  const initialRes = await fetch(serviceUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (initialRes.status !== 402) {
    // Shouldn't happen on first call, but handle it
    const data = await initialRes.json();
    return data.choices?.[0]?.message?.content || JSON.stringify(data);
  }

  // ── Step 2: Parse challenge ──
  const challenge = await initialRes.json();
  const amount = BigInt(challenge.payment.amount);
  const recipient = challenge.payment.recipient as `0x${string}`;

  console.log(
    `[Agent] Got 402 — payment required: ${formatEther(amount)} wstETH to ${recipient}`
  );

  // ── Step 3: Pay on-chain via claimYield ──
  console.log(`[Agent] Claiming yield from treasury...`);
  const txHash = await walletClient.writeContract({
    address: treasuryAddress,
    abi: agentTreasuryAbi,
    functionName: "claimYield",
    args: [amount, recipient],
  });

  console.log(`[Agent] Payment tx: ${txHash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`[Agent] Confirmed in block ${receipt.blockNumber} (status: ${receipt.status})`);

  // ── Step 4: Retry with credential ──
  const credential = Buffer.from(JSON.stringify({ txHash })).toString("base64");

  console.log(`[Agent] Retrying with payment credential...`);
  const paidRes = await fetch(serviceUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Payment credential=${credential}`,
    },
    body: JSON.stringify(body),
  });

  if (!paidRes.ok) {
    const err = await paidRes.json();
    throw new Error(`Payment accepted but service error: ${JSON.stringify(err)}`);
  }

  const paymentReceipt = paidRes.headers.get("Payment-Receipt");
  if (paymentReceipt) {
    console.log(`[Agent] Payment receipt: ${paymentReceipt}`);
  }

  const data = await paidRes.json();
  return data.choices?.[0]?.message?.content || JSON.stringify(data);
}

// ─── Main ────────────────────────────────────────────────

async function main() {
  console.log("╔══════════════════════════════════════════════════════╗");
  console.log("║   stETH Agent Treasury — MPP Demo Agent             ║");
  console.log("║   Paying for AI with staking yield                  ║");
  console.log("╚══════════════════════════════════════════════════════╝");
  console.log(`\nAgent wallet: ${account.address}`);
  console.log(`Treasury:     ${treasuryAddress}`);
  console.log(`Service:      ${serviceUrl}`);

  // Print initial status
  const statusBefore = await getStatus();
  printStatus("Treasury Status (Before)", statusBefore);

  // Get prompt from CLI args or use default
  const prompt =
    process.argv[2] || "What are the top 3 DeFi protocols by TVL? Be brief.";
  console.log(`\n[Agent] Prompt: "${prompt}"`);

  // Make paid API call
  try {
    const response = await paidApiCall(prompt);
    console.log(`\n── AI Response ──`);
    console.log(response);
  } catch (err: any) {
    console.error(`\n[Agent] Error: ${err.message}`);
    process.exit(1);
  }

  // Print final status
  const statusAfter = await getStatus();
  printStatus("Treasury Status (After)", statusAfter);

  // Summary
  const yieldSpent = statusBefore.availableYield - statusAfter.availableYield;
  console.log(`\n── Summary ──`);
  console.log(`  Yield spent:        ${formatEther(yieldSpent)} wstETH`);
  console.log(
    `  Principal unchanged: ${statusBefore.principalValueStETH === statusAfter.principalValueStETH ? "YES" : "NO"}`
  );
  console.log(`  Remaining yield:    ${formatEther(statusAfter.availableYield)} wstETH`);

  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
