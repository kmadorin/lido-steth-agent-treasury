#!/usr/bin/env bash
set -euo pipefail

# ─── stETH Agent Treasury — Full Demo ─────────────────────
# Usage: ./run-demo.sh ["optional prompt"]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RPC="http://127.0.0.1:8545"
ANVIL_PID=""
SERVER_PID=""

# Addresses
WSTETH="0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452"
WHALE="0x31b7538090C8584FED3a053FD183E202c26f9a3e"  # ~750 wstETH on Base
OWNER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
OWNER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
AGENT="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SERVER="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

cleanup() {
  echo ""
  echo "[Demo] Cleaning up..."
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
  echo "[Demo] Done."
}
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════╗"
echo "║   stETH Agent Treasury — MPP Demo                   ║"
echo "║   Agent pays for AI with staking yield via HTTP 402  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ── Step 1: Start Anvil ──
echo ""
echo "[1/5] Starting Anvil (Base mainnet fork)..."
pkill -f "anvil.*8545" 2>/dev/null || true
sleep 1
anvil --fork-url https://mainnet.base.org --port 8545 --silent &
ANVIL_PID=$!

for i in $(seq 1 30); do
  cast chain-id --rpc-url "$RPC" &>/dev/null && break
  [ "$i" -eq 30 ] && { echo "ERROR: Anvil failed"; exit 1; }
  sleep 0.5
done
echo "      Anvil ready (pid $ANVIL_PID)"

# ── Step 2: Deploy contract ──
echo ""
echo "[2/5] Deploying AgentTreasury..."
cd "$PROJECT_DIR"
DEPLOY_OUT=$(forge script script/SetupDemo.s.sol --rpc-url "$RPC" --broadcast --silent 2>&1)
TREASURY=$(echo "$DEPLOY_OUT" | grep "Treasury:" | awk '{print $NF}' | tr -d '[:space:]')
[ -z "$TREASURY" ] && { echo "ERROR: Deploy failed"; echo "$DEPLOY_OUT"; exit 1; }
echo "      Treasury: $TREASURY"

# ── Step 3: Fund & configure via cast ──
echo ""
echo "[3/5] Funding owner from whale & configuring..."

# Impersonate whale, transfer 100 wstETH to owner
cast rpc anvil_impersonateAccount "$WHALE" --rpc-url "$RPC" > /dev/null
cast send "$WSTETH" "transfer(address,uint256)(bool)" "$OWNER" 100000000000000000000 \
  --from "$WHALE" --rpc-url "$RPC" --unlocked > /dev/null
cast rpc anvil_stopImpersonatingAccount "$WHALE" --rpc-url "$RPC" > /dev/null
echo "      Transferred 100 wstETH from whale to owner"

# Owner: approve treasury
cast send "$WSTETH" "approve(address,uint256)(bool)" "$TREASURY" \
  115792089237316195423570985008687907853269984665640564039457584007913129639935 \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" > /dev/null
echo "      Approved treasury"

# Owner: deposit 10 wstETH as principal
cast send "$TREASURY" "deposit(uint256)" 10000000000000000000 \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" > /dev/null
echo "      Deposited 10 wstETH principal"

# Owner: top up 0.1 wstETH as spendable yield
cast send "$TREASURY" "topUpYield(uint256)" 100000000000000000 \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" > /dev/null
echo "      Topped up 0.1 wstETH yield"

# Owner: whitelist server
cast send "$TREASURY" "addRecipient(address)" "$SERVER" \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" > /dev/null
echo "      Whitelisted server: $SERVER"

# Owner: set max per tx to 0.001 wstETH
cast send "$TREASURY" "setMaxPerTransaction(uint128)" 1000000000000000 \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" > /dev/null
echo "      Set max per tx: 0.001 wstETH"

# Verify
YIELD=$(cast call "$TREASURY" "getAvailableYield()(uint256)" --rpc-url "$RPC")
PRINCIPAL=$(cast call "$TREASURY" "wstETHDeposited()(uint256)" --rpc-url "$RPC")
echo "      Available yield: $YIELD wei"
echo "      Principal:       $PRINCIPAL wei"

# ── Step 4: Start MPP service ──
echo ""
echo "[4/5] Starting MPP demo service..."
cd "$SCRIPT_DIR"
TREASURY_ADDRESS="$TREASURY" npx tsx src/server.ts &
SERVER_PID=$!
sleep 2

curl -sf http://localhost:3001/health > /dev/null || { echo "ERROR: Server failed"; exit 1; }
echo "      MPP service ready (pid $SERVER_PID)"

# ── Step 5: Run agent ──
echo ""
echo "[5/5] Running AI agent..."
PROMPT="${1:-What are the top 3 DeFi protocols by TVL? Answer in 2-3 sentences.}"

TREASURY_ADDRESS="$TREASURY" npx tsx src/agent.ts "$PROMPT"

# Final verification
echo ""
echo "── Final Verification ──"
PRINCIPAL_AFTER=$(cast call "$TREASURY" "wstETHDeposited()(uint256)" --rpc-url "$RPC")
echo "  Principal before: $PRINCIPAL"
echo "  Principal after:  $PRINCIPAL_AFTER"
if [ "$PRINCIPAL" = "$PRINCIPAL_AFTER" ]; then
  echo "  Result: PRINCIPAL UNCHANGED — agent paid only from yield"
else
  echo "  Result: WARNING — principal changed!"
fi
