import { Hono } from "hono";
import { serve } from "@hono/node-server";
import {
  SERVER_ADDRESS,
  SERVER_PORT,
  OPENROUTER_API_KEY,
  PRICE_PER_CALL,
} from "./config.js";
import { verifyPayment } from "./verify.js";

const app = new Hono();

// ─── Health check ────────────────────────────────────────
app.get("/health", (c) => c.json({ status: "ok" }));

// ─── MPP-compatible payment middleware ───────────────────
app.post("/v1/chat/completions", async (c) => {
  const authHeader = c.req.header("Authorization");

  // ── Check for payment credential ──
  if (authHeader?.startsWith("Payment ")) {
    // Parse credential: base64-encoded JSON { txHash: "0x..." }
    const credentialB64 = authHeader.slice("Payment credential=".length);
    let txHash: `0x${string}`;

    try {
      const decoded = JSON.parse(
        Buffer.from(credentialB64, "base64").toString()
      );
      txHash = decoded.txHash;
    } catch {
      return c.json({ error: "Invalid credential encoding" }, 400);
    }

    // ── Verify on-chain payment ──
    try {
      const result = await verifyPayment(
        txHash,
        SERVER_ADDRESS,
        PRICE_PER_CALL
      );

      console.log(
        `[MPP] Payment verified: ${result.amount} wstETH wei from ${result.from} (tx: ${txHash})`
      );

      // ── Proxy to OpenRouter ──
      const body = await c.req.json();

      if (!OPENROUTER_API_KEY) {
        return c.json({ error: "OPENROUTER_API_KEY not configured" }, 500);
      }

      const openRouterRes = await fetch(
        "https://openrouter.ai/api/v1/chat/completions",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${OPENROUTER_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        }
      );

      const data = await openRouterRes.json();

      // Return with MPP receipt header
      return c.json(data, 200, {
        "Payment-Receipt": `method="wsteth-yield", reference="${txHash}"`,
      });
    } catch (err: any) {
      console.error(`[MPP] Verification failed: ${err.message}`);
      return c.json({ error: "Payment verification failed", detail: err.message }, 402);
    }
  }

  // ── No credential → return 402 challenge ──
  const challenge = [
    `method="wsteth-yield"`,
    `intent="charge"`,
    `amount="${PRICE_PER_CALL.toString()}"`,
    `currency="wsteth"`,
    `recipient="${SERVER_ADDRESS}"`,
    `chainId="8453"`,
  ].join(", ");

  return c.json(
    {
      error: "Payment Required",
      description:
        "This endpoint requires wstETH payment via the AgentTreasury contract.",
      payment: {
        method: "wsteth-yield",
        amount: PRICE_PER_CALL.toString(),
        currency: "wsteth",
        recipient: SERVER_ADDRESS,
        chainId: 8453,
      },
    },
    402,
    { "WWW-Authenticate": `Payment ${challenge}` }
  );
});

// ─── Start ───────────────────────────────────────────────
console.log(`[MPP Demo Service] Starting on port ${SERVER_PORT}...`);
console.log(`[MPP Demo Service] Server address: ${SERVER_ADDRESS}`);
console.log(`[MPP Demo Service] Price per call: ${PRICE_PER_CALL} wstETH wei`);
console.log(
  `[MPP Demo Service] OpenRouter key: ${OPENROUTER_API_KEY ? "configured" : "MISSING"}`
);

serve({ fetch: app.fetch, port: SERVER_PORT }, (info) => {
  console.log(`[MPP Demo Service] Listening on http://localhost:${info.port}`);
});
