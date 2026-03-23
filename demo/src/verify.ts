import { createPublicClient, http, parseAbiItem, type Hash } from "viem";
import { base } from "viem/chains";
import { RPC_URL, WSTETH_ADDRESS, CHAIN_ID } from "./config.js";

const publicClient = createPublicClient({
  chain: { ...base, id: CHAIN_ID },
  transport: http(RPC_URL),
});

const transferEvent = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)"
);

export interface VerifyResult {
  valid: boolean;
  from: string;
  to: string;
  amount: bigint;
  txHash: Hash;
}

/**
 * Verify an on-chain wstETH transfer matches the payment requirements.
 */
export async function verifyPayment(
  txHash: Hash,
  expectedRecipient: string,
  minAmount: bigint
): Promise<VerifyResult> {
  const receipt = await publicClient.getTransactionReceipt({ hash: txHash });

  if (receipt.status !== "success") {
    throw new Error(`Transaction ${txHash} reverted`);
  }

  // Find wstETH Transfer events
  const transferLogs = receipt.logs.filter(
    (log) =>
      log.address.toLowerCase() === WSTETH_ADDRESS.toLowerCase() &&
      log.topics[0] === // Transfer(address,address,uint256) topic
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  );

  for (const log of transferLogs) {
    const to = ("0x" + log.topics[2]!.slice(26)) as `0x${string}`;
    const value = BigInt(log.data);

    if (
      to.toLowerCase() === expectedRecipient.toLowerCase() &&
      value >= minAmount
    ) {
      const from = ("0x" + log.topics[1]!.slice(26)) as `0x${string}`;
      return { valid: true, from, to, amount: value, txHash };
    }
  }

  throw new Error(
    `No valid wstETH transfer to ${expectedRecipient} for >= ${minAmount} wei in tx ${txHash}`
  );
}
