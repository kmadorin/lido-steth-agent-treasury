# Smart Contract PRD: stETH Agent Treasury

**Parent PRD:** `docs/PRD.md` (v1.2)
**Scope:** Solidity contracts only — `AgentTreasury.sol`, `RateOracle.sol`, interfaces, and deployment
**Toolchain:** Foundry / Forge
**Target chain:** Base (8453), tested on Base mainnet fork
**Compiler:** Solidity 0.8.24+

---

## 1. Goal

Build and deploy two smart contracts on Base:

1. **`AgentTreasury`** — a yield-splitting vault that holds wstETH, tracks principal vs. yield via an external rate oracle, lets only the owner touch principal, and lets only the agent spend yield within configurable permission bounds.
2. **`RateOracle`** — an owner-updatable oracle that provides the `stEthPerToken` rate on Base (where the bridged wstETH lacks this function natively).

The contracts must satisfy the bounty's four hard requirements:
- Principal structurally inaccessible to the agent
- A spendable yield balance the agent can query and draw from
- At least one configurable permission (we implement three: whitelist, per-tx cap, time window)
- Deployed on a real chain, no mocks

---

## 2. On-Chain Context: wstETH on Base

### 2.1 Verified Contract Details (from Blockscout)

| Property | Value |
|----------|-------|
| Address | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` |
| Proxy type | EIP-1967 (`OssifiableProxy`) |
| Implementation | `ERC20Bridged` at `0x69ce2505CE515C0203160450157366F927243309` |
| Name | Superbridge Bridged wstETH (Base) |
| Symbol | WSTETH |
| Decimals | 18 |
| Total supply | ~35,886 wstETH |
| Holders | ~468,000 |

### 2.2 What ERC20Bridged Means for Us

The Base wstETH is a **plain ERC-20**. It does NOT expose:
- `stEthPerToken()`
- `getStETHByWstETH(uint256)`
- `wrap(uint256)` / `unwrap(uint256)`

These only exist on the mainnet `WstETH` contract (`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`, Solidity 0.6.12).

Therefore, the contract interacts with wstETH **only via IERC20** (`transfer`, `transferFrom`, `balanceOf`, `approve`). The exchange rate comes from the `RateOracle`.

### 2.3 Mainnet wstETH for Reference

On Ethereum mainnet, `stEthPerToken()` returns the amount of stETH backing 1 wstETH (18 decimals). It monotonically increases as Lido staking rewards accrue, approximately ~3.5% APR. The Lido oracle reports once daily (9 daemons, 5-of-9 quorum, sanity cap: max 27% daily APR, max 5% decrease). Current value is approximately `1.2e18` (1 wstETH ≈ 1.2 stETH).

---

## 3. Contract Architecture

### 3.1 File Tree

```
src/
  AgentTreasury.sol       — core vault
  RateOracle.sol          — owner-updatable rate feed
  interfaces/
    IRateOracle.sol       — rate oracle interface
test/
  AgentTreasury.t.sol     — unit + integration tests
  AgentTreasury.fuzz.t.sol — fuzz / invariant tests
  RateOracle.t.sol        — oracle unit tests
  helpers/
    BaseMainnetFork.sol   — base class for fork tests
script/
  DeployAll.s.sol         — deploy oracle + treasury
  UpdateRate.s.sol        — push rate to oracle
```

### 3.2 Dependencies (Foundry remappings)

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

Install:
```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
```

### 3.3 Inheritance Diagram

```
AgentTreasury
  ├── AccessControl          (OZ — role-based permissions)
  ├── ReentrancyGuard        (OZ — reentrancy protection)
  └── Pausable               (OZ — emergency circuit breaker)

RateOracle
  └── Ownable                (OZ — single owner for rate updates)
```

---

## 4. `IRateOracle` Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRateOracle {
    /// @notice Returns the current stETH-per-wstETH rate, 18 decimals.
    /// @dev On L1 this would wrap wstETH.stEthPerToken().
    ///      On L2 this is pushed by an off-chain keeper.
    /// @return rate  stETH per 1 wstETH (e.g., 1.2e18 means 1 wstETH = 1.2 stETH)
    function getRate() external view returns (uint256 rate);
}
```

---

## 5. `RateOracle` Contract

### 5.1 Purpose

Provides the wstETH → stETH exchange rate on Base. Since the bridged wstETH is a plain ERC-20 without `stEthPerToken()`, a trusted updater pushes the rate from L1.

### 5.2 Storage

| Variable | Type | Description |
|----------|------|-------------|
| `rate` | `uint256` | Current stETH per wstETH, 18 decimals |
| `lastUpdated` | `uint256` | Block timestamp of last update |

Both inherited from `Ownable`: `_owner`.

### 5.3 Functions

```solidity
constructor(address initialOwner, uint256 initialRate)
```
- Sets owner, sets initial rate, sets `lastUpdated = block.timestamp`.
- Reverts if `initialRate == 0`.

```solidity
function setRate(uint256 _rate) external onlyOwner
```
- Updates `rate` and `lastUpdated`.
- Reverts if `_rate == 0`.
- Emits `RateUpdated(uint256 newRate, uint256 timestamp)`.

```solidity
function getRate() external view returns (uint256)
```
- Returns `rate`. Does NOT revert if stale; staleness is the caller's concern.

### 5.4 Events

```solidity
event RateUpdated(uint256 indexed newRate, uint256 timestamp);
```

### 5.5 Errors

```solidity
error InvalidRate();
```

### 5.6 Operational Notes

- The rate should be pushed at least once per day (after Lido oracle reports).
- For hackathon: the deployer/owner reads `stEthPerToken()` from mainnet via `cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 "stEthPerToken()(uint256)" --rpc-url $ETH_RPC` and pushes it to Base.
- A Foundry script (`UpdateRate.s.sol`) automates this.
- In production, replace with Chainlink wstETH/stETH feed or a cross-chain oracle (CCIP, LayerZero).

---

## 6. `AgentTreasury` Contract — Detailed Specification

### 6.1 Roles

```solidity
bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
```

| Role | Who | Can Do |
|------|-----|--------|
| `OWNER_ROLE` | Human wallet | `deposit`, `withdrawPrincipal`, `emergencyWithdraw`, all permission setters, `setRateOracle`, `pause`, `unpause`, grant/revoke agent & guardian |
| `AGENT_ROLE` | AI agent EOA | `claimYield` (within permission bounds) |
| `GUARDIAN_ROLE` | Optional 3rd party | `pause` only |
| `DEFAULT_ADMIN_ROLE` | Deployer initially | Admin for all roles. **Renounced** in constructor after granting `OWNER_ROLE`. |

Role admin setup in constructor:
- `DEFAULT_ADMIN_ROLE` admin for `OWNER_ROLE`
- `OWNER_ROLE` admin for `AGENT_ROLE` and `GUARDIAN_ROLE`
- Deployer renounces `DEFAULT_ADMIN_ROLE` after granting `OWNER_ROLE` to the human wallet

### 6.2 Immutables

```solidity
IERC20 public immutable wstETH;
```

Set in constructor. The wstETH token address on the target chain.

### 6.3 State Variables

#### Principal Tracking

| Variable | Type | Slot | Description |
|----------|------|------|-------------|
| `rateOracle` | `IRateOracle` | 0 | Address of the rate oracle contract |
| `wstETHDeposited` | `uint256` | 1 | Total wstETH principal deposited (W) |
| `initialRate` | `uint256` | 2 | stEthPerToken at deposit/re-anchor time (R₀) |
| `pendingYieldBonus` | `uint256` | 3 | Unclaimed yield carried from re-anchoring (wstETH) |
| `totalYieldClaimed` | `uint256` | 4 | Cumulative wstETH claimed as yield |

#### Permissions

| Variable | Type | Slot | Description |
|----------|------|------|-------------|
| `whitelistedRecipients` | `mapping(address => bool)` | 5 | Recipient whitelist |
| `maxPerTransaction` | `uint128` | 6 (lower) | Max wstETH per claim, 0 = unlimited |
| `spendingLimit` | `uint128` | 6 (upper) | Max wstETH per window, 0 = unlimited |
| `spendingWindow` | `uint64` | 7 (bytes 0-7) | Window duration in seconds |
| `windowStart` | `uint64` | 7 (bytes 8-15) | Current window start timestamp |
| `spentInCurrentWindow` | `uint128` | 7 (bytes 16-31) | wstETH spent in current window |
| `cooldownPeriod` | `uint64` | 8 (bytes 0-7) | Seconds between claims, 0 = disabled |
| `lastClaimTimestamp` | `uint64` | 8 (bytes 8-15) | Timestamp of last yield claim |

**Storage packing rationale:**
- `uint128` for wstETH amounts: max ≈ 3.4 × 10³⁸ wei ≈ 3.4 × 10²⁰ ETH — far exceeds all ETH in existence
- `uint64` for timestamps: max ≈ year 584 billion — sufficient
- Slot 6: two `uint128` values = 32 bytes (1 SLOAD for both)
- Slot 7: `uint64` + `uint64` + `uint128` = 32 bytes (1 SLOAD for full window check)
- Slot 8: `uint64` + `uint64` = 16 bytes (1 SLOAD for cooldown check)

### 6.4 Constructor

```solidity
constructor(
    address _wstETH,
    address _rateOracle,
    address _owner,
    address _agent
)
```

1. Validate: all four addresses non-zero
2. Set `wstETH = IERC20(_wstETH)` (immutable)
3. Set `rateOracle = IRateOracle(_rateOracle)`
4. Grant `OWNER_ROLE` to `_owner`
5. Grant `AGENT_ROLE` to `_agent`
6. Set `OWNER_ROLE` as role admin for `AGENT_ROLE` and `GUARDIAN_ROLE`
7. Renounce `DEFAULT_ADMIN_ROLE` from deployer
8. No initial deposit in constructor — owner calls `deposit()` separately

### 6.5 Yield Calculation — Detailed Math

#### Core Formula

Given:
- `W` = `wstETHDeposited` (in wstETH wei, 18 decimals)
- `R₀` = `initialRate` (stETH per wstETH at deposit, 18 decimals)
- `Rₜ` = `rateOracle.getRate()` (current stETH per wstETH, 18 decimals)

The yield accrued since the last anchor, expressed in **wstETH**:

```
yieldFromRate = Math.mulDiv(W, Rₜ - R₀, Rₜ)    // if Rₜ > R₀, else 0
```

Total available yield:

```
totalAvailable = yieldFromRate + pendingYieldBonus
availableYield = totalAvailable > totalYieldClaimed
    ? totalAvailable - totalYieldClaimed
    : 0
```

#### Why `Math.mulDiv`

The multiplication `W * (Rₜ - R₀)` can overflow `uint256` if `W` is very large and `Rₜ - R₀` is large. `Math.mulDiv(a, b, c)` computes `(a * b) / c` using 512-bit intermediate, avoiding overflow.

#### Proof of Principal Preservation

After withdrawing `Y_wstETH` of yield, remaining wstETH:

```
W_remaining = W - Y_wstETH
            = W - W × (Rₜ - R₀) / Rₜ
            = W × R₀ / Rₜ
```

Value of remaining wstETH in stETH terms:

```
V_remaining = W_remaining × Rₜ / 1e18
            = (W × R₀ / Rₜ) × Rₜ / 1e18
            = W × R₀ / 1e18
            = P  (the original principal in stETH)
```

#### Rounding Direction

All yield calculations round **DOWN** (in favor of the vault / principal). Use `Math.mulDiv` with default (floor) rounding. The `_principalWstETHFloor()` helper uses **ceiling division** to ensure the principal floor is never underestimated:

```solidity
function _principalWstETHFloor() internal view returns (uint256) {
    uint256 currentRate = _currentRate();
    if (currentRate == 0 || wstETHDeposited == 0) return 0;
    // Ceiling division: (a + b - 1) / b
    return Math.mulDiv(wstETHDeposited, initialRate, currentRate, Math.Rounding.Ceil);
}
```

#### Multiple Deposits — Re-Anchoring

When the owner calls `deposit()` after an initial deposit already exists:

```
1. currentYield = _calculateRawYield()   // yieldFromRate in wstETH
2. unclaimedYield = currentYield + pendingYieldBonus - totalYieldClaimed
3. pendingYieldBonus = unclaimedYield    // carry over unclaimed yield
4. totalYieldClaimed = 0                 // reset claim counter
5. initialRate = _currentRate()          // re-anchor to current rate
6. wstETHDeposited += newAmount          // add new deposit
```

This ensures previously accrued but unclaimed yield is preserved.

#### Owner Withdrawal — Adjusting State

When the owner withdraws wstETH via `withdrawPrincipal()`:

- If `amount >= wstETH.balanceOf(address(this))`: full withdrawal, reset all state to zero
- Otherwise: reduce `wstETHDeposited` proportionally. Re-anchor to current rate. Carry unclaimed yield into `pendingYieldBonus`.

#### Edge Cases

| Condition | Behavior |
|-----------|----------|
| `Rₜ < R₀` (slashing) | `getAvailableYield()` returns `pendingYieldBonus - totalYieldClaimed` (or 0 if none). Agent cannot claim yield from rate delta. |
| `Rₜ == R₀` | No new yield from rate. Only `pendingYieldBonus` if any. |
| `wstETHDeposited == 0` | All yield functions return 0. |
| `rateOracle.getRate() == 0` | Treat as "rate unavailable". Yield from rate = 0. Only `pendingYieldBonus` claimable. |
| Very small yield (< 1 wei) | `mulDiv` rounds to 0. Agent cannot claim 0. |

### 6.6 Functions — Complete Specification

---

#### `deposit(uint256 amount)`

**Access:** `OWNER_ROLE` only
**Modifiers:** `nonReentrant`, `whenNotPaused`

**Logic:**
1. Revert if `amount == 0` → `ZeroAmount()`
2. If `wstETHDeposited > 0`: re-anchor (compute `pendingYieldBonus`, reset `totalYieldClaimed`, update `initialRate`)
3. If `wstETHDeposited == 0`: set `initialRate = _currentRate()`; revert if rate is 0 → `InvalidRate()`
4. `wstETHDeposited += amount`
5. `wstETH.safeTransferFrom(msg.sender, address(this), amount)`
6. Emit `Deposited(msg.sender, amount, initialRate)`

---

#### `withdrawPrincipal(uint256 amount, address to)`

**Access:** `OWNER_ROLE` only
**Modifiers:** `nonReentrant`
**Note:** NOT gated by `whenNotPaused` — owner can always recover funds even when paused.

**Logic:**
1. Revert if `to == address(0)` → `ZeroAddress()`
2. Revert if `amount == 0` → `ZeroAmount()`
3. `uint256 balance = wstETH.balanceOf(address(this))`
4. Revert if `amount > balance`
5. If `amount == balance`: reset all state (`wstETHDeposited = 0`, `initialRate = 0`, `pendingYieldBonus = 0`, `totalYieldClaimed = 0`)
6. Else: re-anchor first, then `wstETHDeposited -= amount` (may underflow check needed if amount > deposited; cap at deposited)
7. `wstETH.safeTransfer(to, amount)`
8. Emit `PrincipalWithdrawn(msg.sender, amount, to)`

---

#### `emergencyWithdraw(address to)`

**Access:** `OWNER_ROLE` only
**Modifiers:** `nonReentrant`

**Logic:**
1. Transfer entire `wstETH.balanceOf(address(this))` to `to`
2. Reset all state to zero
3. Emit `EmergencyWithdraw(msg.sender, amount, to)`

---

#### `claimYield(uint256 amount, address recipient)`

**Access:** `AGENT_ROLE` only
**Modifiers:** `nonReentrant`, `whenNotPaused`

**Logic (CEI — Checks, Effects, Interactions):**

```
// ── CHECKS ──
1. if (!whitelistedRecipients[recipient]) revert RecipientNotWhitelisted(recipient);
2. uint256 available = getAvailableYield();
3. if (amount > available) revert ExceedsAvailableYield(amount, available);
4. if (amount == 0) revert ZeroAmount();
5. if (maxPerTransaction != 0 && amount > maxPerTransaction)
       revert ExceedsPerTransactionCap(amount, maxPerTransaction);
6. _enforceSpendingWindow(amount);    // reverts if over window limit
7. _enforceCooldown();                // reverts if cooldown not elapsed

// ── EFFECTS ──
8. totalYieldClaimed += amount;
9. lastClaimTimestamp = uint64(block.timestamp);

// ── INTERACTIONS ──
10. wstETH.safeTransfer(recipient, amount);

// ── POST-CONDITION (belt-and-suspenders) ──
11. uint256 minRequired = _principalWstETHFloor();
12. if (wstETH.balanceOf(address(this)) < minRequired)
        revert PrincipalViolation(wstETH.balanceOf(address(this)), minRequired);

13. emit YieldClaimed(msg.sender, amount, recipient);
```

---

#### `getAvailableYield() → uint256`

**Access:** Public view

```
1. uint256 currentRate = _currentRate();
2. uint256 yieldFromRate = 0;
3. if (currentRate > initialRate && wstETHDeposited > 0) {
       yieldFromRate = Math.mulDiv(wstETHDeposited, currentRate - initialRate, currentRate);
   }
4. uint256 totalAvailable = yieldFromRate + pendingYieldBonus;
5. return totalAvailable > totalYieldClaimed ? totalAvailable - totalYieldClaimed : 0;
```

---

#### `getAvailableYieldInStETH() → uint256`

**Access:** Public view

```
return Math.mulDiv(getAvailableYield(), _currentRate(), 1e18);
```

---

#### `getPrincipalValue() → uint256`

**Access:** Public view

Returns the original principal value in stETH terms:
```
return Math.mulDiv(wstETHDeposited, initialRate, 1e18);
```

---

#### `getTotalValue() → uint256`

**Access:** Public view

Returns total current value (principal + unclaimed yield) in stETH terms:
```
return Math.mulDiv(wstETH.balanceOf(address(this)), _currentRate(), 1e18);
```

---

#### Permission Setters (all `OWNER_ROLE` only)

```solidity
function addRecipient(address recipient) external onlyRole(OWNER_ROLE);
function removeRecipient(address recipient) external onlyRole(OWNER_ROLE);
function addRecipientsBatch(address[] calldata recipients) external onlyRole(OWNER_ROLE);
function setMaxPerTransaction(uint128 amount) external onlyRole(OWNER_ROLE);
function setSpendingLimit(uint128 limit, uint64 window) external onlyRole(OWNER_ROLE);
function setCooldownPeriod(uint64 period) external onlyRole(OWNER_ROLE);
function setRateOracle(address newOracle) external onlyRole(OWNER_ROLE);
```

Each setter emits a corresponding event.

`setSpendingLimit` resets `windowStart` and `spentInCurrentWindow` to 0 when called (fresh window starts on next claim).

---

#### Pause / Unpause

```solidity
function pause() external {
    if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender))
        revert NotAuthorized();
    _pause();
}

function unpause() external onlyRole(OWNER_ROLE) {
    _unpause();
}
```

Pause blocks: `deposit`, `claimYield`.
Pause does NOT block: `withdrawPrincipal`, `emergencyWithdraw` (owner must always recover).

---

#### Internal Helpers

```solidity
function _currentRate() internal view returns (uint256) {
    return rateOracle.getRate();
}

function _principalWstETHFloor() internal view returns (uint256) {
    uint256 currentRate = _currentRate();
    if (currentRate == 0 || wstETHDeposited == 0) return 0;
    return Math.mulDiv(wstETHDeposited, initialRate, currentRate, Math.Rounding.Ceil);
}

function _enforceSpendingWindow(uint256 amount) internal {
    if (spendingLimit == 0) return;  // no limit set
    if (block.timestamp >= uint256(windowStart) + uint256(spendingWindow)) {
        // New window
        windowStart = uint64(block.timestamp);
        spentInCurrentWindow = 0;
    }
    if (uint256(spentInCurrentWindow) + amount > uint256(spendingLimit))
        revert ExceedsSpendingWindowLimit(amount, uint256(spendingLimit) - uint256(spentInCurrentWindow));
    spentInCurrentWindow += uint128(amount);
}

function _enforceCooldown() internal view {
    if (cooldownPeriod == 0) return;
    if (block.timestamp < uint256(lastClaimTimestamp) + uint256(cooldownPeriod))
        revert CooldownNotElapsed(uint256(lastClaimTimestamp) + uint256(cooldownPeriod));
}

function _reanchor() internal {
    uint256 currentRate = _currentRate();
    if (currentRate == 0 || wstETHDeposited == 0) return;

    uint256 yieldFromRate = 0;
    if (currentRate > initialRate) {
        yieldFromRate = Math.mulDiv(wstETHDeposited, currentRate - initialRate, currentRate);
    }
    uint256 totalAvailable = yieldFromRate + pendingYieldBonus;
    uint256 unclaimed = totalAvailable > totalYieldClaimed
        ? totalAvailable - totalYieldClaimed
        : 0;

    pendingYieldBonus = unclaimed;
    totalYieldClaimed = 0;
    initialRate = currentRate;
}
```

### 6.7 Events

```solidity
event Deposited(address indexed owner, uint256 wstETHAmount, uint256 rateAtDeposit);
event PrincipalWithdrawn(address indexed owner, uint256 wstETHAmount, address indexed to);
event EmergencyWithdraw(address indexed owner, uint256 wstETHAmount, address indexed to);
event YieldClaimed(address indexed agent, uint256 wstETHAmount, address indexed recipient);
event RecipientWhitelisted(address indexed recipient, bool status);
event MaxPerTransactionUpdated(uint128 oldValue, uint128 newValue);
event SpendingLimitUpdated(uint128 limit, uint64 window);
event CooldownPeriodUpdated(uint64 oldPeriod, uint64 newPeriod);
event RateOracleUpdated(address indexed oldOracle, address indexed newOracle);
```

### 6.8 Custom Errors

```solidity
error NotAuthorized();
error ZeroAddress();
error ZeroAmount();
error InvalidRate();
error RecipientNotWhitelisted(address recipient);
error ExceedsAvailableYield(uint256 requested, uint256 available);
error ExceedsPerTransactionCap(uint256 requested, uint256 cap);
error ExceedsSpendingWindowLimit(uint256 requested, uint256 remaining);
error CooldownNotElapsed(uint256 nextAllowedTimestamp);
error PrincipalViolation(uint256 remainingBalance, uint256 requiredMinimum);
error InsufficientBalance();
```

---

## 7. Principal Isolation — Structural Guarantees

This is the most important property. The contract must make it **impossible** for the agent to access principal, regardless of call sequences or parameter values.

### 7.1 Why It's Structural, Not Policy

| Guarantee | How It's Enforced |
|-----------|-------------------|
| Agent has no `withdraw` function | Only `claimYield` is available to `AGENT_ROLE`. No `transfer`, no `withdraw`, no `execute`. |
| `claimYield` is mathematically bounded | `amount ≤ getAvailableYield()` which computes `W × (Rₜ - R₀) / Rₜ + bonus - claimed`. Maximum possible extraction = yield only. |
| Post-condition assertion | After every `claimYield`, verify `wstETH.balanceOf(this) >= _principalWstETHFloor()`. Reverts entire tx if violated. |
| No delegatecall | The contract contains no `delegatecall` or `call` with arbitrary data. |
| No approval exposure | The contract never calls `wstETH.approve()` for external contracts on behalf of the agent. |
| No self-destruct | The contract has no `selfdestruct`. |
| Immutable deployment | No proxy, no upgradeability. Code cannot change post-deployment. |

### 7.2 The Only Way Principal Decreases

Owner explicitly calls `withdrawPrincipal()` or `emergencyWithdraw()`. Both are gated by `OWNER_ROLE`.

---

## 8. Security Analysis

### 8.1 Threat Model

| # | Threat | Severity | Mitigation |
|---|--------|----------|------------|
| 1 | Reentrancy on `claimYield` | HIGH | `ReentrancyGuard` + CEI pattern. `totalYieldClaimed` updated before `safeTransfer`. wstETH is a standard ERC-20 (no hooks), but guard is belt-and-suspenders. |
| 2 | Rate oracle manipulation | MEDIUM | Oracle is owner-controlled. Agent cannot update it. Bounded by sanity: `setRate` rejects `rate == 0`. In fork tests, verify against real L1 values. |
| 3 | Rounding exploits | LOW | All yield calcs round DOWN (favor vault). `_principalWstETHFloor` rounds UP (ceiling). `Math.mulDiv` prevents overflow. |
| 4 | Agent front-runs oracle update | LOW | Agent could wait for a rate increase then immediately claim. Mitigation: spending window limits cap burst claims. Economically insignificant at ~3.5% APR. |
| 5 | Owner-as-attacker | N/A | Owner can always withdraw everything. This is by design — it's the owner's money. The contract protects the owner from the agent, not vice versa. |
| 6 | Stale oracle | MEDIUM | `lastUpdated` timestamp on RateOracle is public. Off-chain monitoring can warn. The contract does not enforce staleness checks to avoid bricking yield claims if the keeper is temporarily down. |
| 7 | Overflow in yield calc | LOW | `Math.mulDiv` uses 512-bit intermediate. Solidity 0.8+ has built-in overflow checks on all other arithmetic. |
| 8 | Permission bypass | LOW | No `delegatecall`, no `call` with arbitrary data, no `execute`. The agent cannot craft transactions that bypass permission checks. |
| 9 | Denial of service by agent | LOW | Agent cannot block owner operations. `withdrawPrincipal` and `emergencyWithdraw` have no dependencies on agent-controlled state and are not paused-gated. |
| 10 | `safeTransfer` failure | LOW | If wstETH transfer fails (e.g., contract paused upstream), the entire tx reverts cleanly. No stuck state. |

### 8.2 Invariants (for Fuzz Testing)

These must hold after **any** sequence of operations:

```
INV-1: wstETH.balanceOf(treasury) >= _principalWstETHFloor()
       "The contract always holds enough wstETH to cover the principal."

INV-2: totalYieldClaimed <= _calculateRawYield() + pendingYieldBonus
       "Cannot claim more yield than has accrued."

INV-3: Agent-callable functions never decrease wstETHDeposited or initialRate.
       "Agent cannot modify principal tracking variables."

INV-4: If paused, claimYield reverts. withdrawPrincipal still succeeds.
       "Pause protects yield but never locks owner funds."

INV-5: getAvailableYield() == 0 when currentRate <= initialRate AND pendingYieldBonus <= totalYieldClaimed.
       "No phantom yield during slashing/flat periods."
```

---

## 9. Testing Strategy

### 9.1 Foundry Configuration

```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false

[profile.default.fuzz]
runs = 1000
max_test_rejects = 100000

[profile.default.invariant]
runs = 256
depth = 50

[rpc_endpoints]
base_mainnet = "${BASE_RPC_URL}"

[etherscan]
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
```

### 9.2 Fork Test Base Class

```solidity
abstract contract BaseMainnetFork is Test {
    uint256 baseFork;

    address constant WSTETH_BASE = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    // Use a real wstETH whale on Base for funding test accounts
    // Find via: cast call $WSTETH_BASE "balanceOf(address)(uint256)" $WHALE --rpc-url $BASE_RPC
    address constant WSTETH_WHALE = <TO_BE_DETERMINED>;

    function setUp() public virtual {
        baseFork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(baseFork);
    }

    function _fundWithWstETH(address to, uint256 amount) internal {
        vm.prank(WSTETH_WHALE);
        IERC20(WSTETH_BASE).transfer(to, amount);
    }
}
```

### 9.3 Test Plan

#### Unit Tests (`AgentTreasury.t.sol`)

**Deposit:**
- `test_deposit_firstDeposit` — records amount, sets initialRate, emits event
- `test_deposit_subsequentDeposit_reanchors` — preserves unclaimed yield, updates rate
- `test_deposit_zeroAmount_reverts` — ZeroAmount error
- `test_deposit_nonOwner_reverts` — AccessControl error
- `test_deposit_whenPaused_reverts` — Pausable error

**Withdraw:**
- `test_withdrawPrincipal_full` — resets all state, transfers all wstETH
- `test_withdrawPrincipal_partial` — reduces deposited amount, re-anchors
- `test_withdrawPrincipal_nonOwner_reverts`
- `test_withdrawPrincipal_whenPaused_succeeds` — owner can always withdraw
- `test_emergencyWithdraw` — transfers all, resets state

**Yield Calculation:**
- `test_getAvailableYield_noDeposit_returnsZero`
- `test_getAvailableYield_rateUnchanged_returnsZero`
- `test_getAvailableYield_rateIncreased_returnsCorrect` — verify against manual calculation
- `test_getAvailableYield_rateDecreased_returnsZero` — slashing scenario
- `test_getAvailableYield_afterPartialClaim` — reduces by claimed amount
- `test_getAvailableYield_afterReanchor` — pendingYieldBonus works correctly
- `test_getAvailableYield_multipleDeposits` — re-anchoring preserves prior yield
- `test_principalPreservation` — claim max yield, verify remaining covers principal

**Claim Yield:**
- `test_claimYield_success` — transfers wstETH to recipient, updates state
- `test_claimYield_nonAgent_reverts`
- `test_claimYield_notWhitelisted_reverts`
- `test_claimYield_exceedsAvailable_reverts`
- `test_claimYield_exceedsPerTxCap_reverts`
- `test_claimYield_exceedsWindowLimit_reverts`
- `test_claimYield_cooldownNotElapsed_reverts`
- `test_claimYield_windowResets_afterExpiry` — new window, counter resets
- `test_claimYield_whenPaused_reverts`
- `test_claimYield_principalPostCondition` — balance >= floor after claim

**Permissions:**
- `test_addRecipient` / `test_removeRecipient` — events emitted
- `test_setMaxPerTransaction` — updates, emits
- `test_setSpendingLimit` — updates, resets window, emits
- `test_setCooldownPeriod` — updates, emits
- `test_addRecipientsBatch` — multiple adds in one tx

#### Fuzz Tests (`AgentTreasury.fuzz.t.sol`)

- `testFuzz_claimYield_neverExceedsPrincipal(uint256 depositAmt, uint256 rateDelta, uint256 claimAmt)` — for any valid inputs, post-claim balance >= principal floor
- `testFuzz_yieldCalculation_matchesFormula(uint256 W, uint256 R0, uint256 Rt)` — getAvailableYield matches `W * (Rt - R0) / Rt`
- `testFuzz_multipleDepositsAndClaims_preservePrincipal(...)` — random deposit/claim sequences always preserve principal
- `testFuzz_spendingWindow_neverExceedsLimit(...)` — random claim sequences within a window never exceed the limit

#### Invariant Tests (`AgentTreasury.invariant.t.sol`)

Handler contract that randomly calls `deposit`, `claimYield`, `withdrawPrincipal`, `setRate`, and permission setters. After each call sequence, check:
- `INV-1` through `INV-5` (see Section 8.2)

#### Oracle Tests (`RateOracle.t.sol`)

- `test_setRate_success`
- `test_setRate_zeroReverts`
- `test_setRate_nonOwnerReverts`
- `test_getRate_returnsLatest`
- `test_constructor_setsInitialRate`

### 9.4 Running Tests

```bash
# Unit tests on Base mainnet fork
forge test --fork-url $BASE_RPC_URL -vvv

# Fuzz tests (more runs for confidence)
forge test --match-path test/AgentTreasury.fuzz.t.sol --fuzz-runs 10000 --fork-url $BASE_RPC_URL

# Invariant tests
forge test --match-path test/AgentTreasury.invariant.t.sol --fork-url $BASE_RPC_URL

# Gas report
forge test --gas-report --fork-url $BASE_RPC_URL

# Coverage
forge coverage --fork-url $BASE_RPC_URL
```

---

## 10. Deployment

### 10.1 Script: `DeployAll.s.sol`

```solidity
contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address agent = vm.envAddress("AGENT_ADDRESS");
        uint256 initialRate = vm.envUint("INITIAL_RATE"); // from L1 stEthPerToken()

        vm.startBroadcast(deployerKey);

        RateOracle oracle = new RateOracle(owner, initialRate);
        AgentTreasury treasury = new AgentTreasury(
            0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452, // wstETH on Base
            address(oracle),
            owner,
            agent
        );

        vm.stopBroadcast();

        console.log("RateOracle:", address(oracle));
        console.log("AgentTreasury:", address(treasury));
    }
}
```

### 10.2 Deployment Steps

```bash
# 1. Get current stEthPerToken from L1
INITIAL_RATE=$(cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
  "stEthPerToken()(uint256)" --rpc-url $ETH_RPC_URL)
echo "Initial rate: $INITIAL_RATE"

# 2. Deploy to Base mainnet
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvv

# 3. Verify on BaseScan (if --verify didn't work)
forge verify-contract $ORACLE_ADDRESS RateOracle \
  --chain base \
  --constructor-args $(cast abi-encode "constructor(address,uint256)" $OWNER $INITIAL_RATE)

forge verify-contract $TREASURY_ADDRESS AgentTreasury \
  --chain base \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
    0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452 $ORACLE_ADDRESS $OWNER $AGENT)
```

### 10.3 Post-Deployment Setup

```bash
# 4. Owner approves treasury to spend wstETH
cast send $WSTETH_BASE "approve(address,uint256)" $TREASURY_ADDRESS $AMOUNT \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

# 5. Owner deposits wstETH
cast send $TREASURY_ADDRESS "deposit(uint256)" $AMOUNT \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

# 6. Owner whitelists recipient(s)
cast send $TREASURY_ADDRESS "addRecipient(address)" $RECIPIENT \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

# 7. Owner sets per-tx cap (e.g., 0.002 wstETH = 2000000000000000 wei)
cast send $TREASURY_ADDRESS "setMaxPerTransaction(uint128)" 2000000000000000 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

# 8. Owner sets daily spending limit (e.g., 0.01 wstETH, 86400s window)
cast send $TREASURY_ADDRESS "setSpendingLimit(uint128,uint64)" 10000000000000000 86400 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY
```

### 10.4 Rate Update Script: `UpdateRate.s.sol`

```solidity
contract UpdateRate is Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 newRate = vm.envUint("NEW_RATE");
        uint256 ownerKey = vm.envUint("OWNER_PRIVATE_KEY");

        vm.startBroadcast(ownerKey);
        RateOracle(oracle).setRate(newRate);
        vm.stopBroadcast();
    }
}
```

Usage:
```bash
NEW_RATE=$(cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
  "stEthPerToken()(uint256)" --rpc-url $ETH_RPC_URL)
forge script script/UpdateRate.s.sol:UpdateRate \
  --rpc-url $BASE_RPC_URL --broadcast -vvv
```

---

## 11. Gas Optimization Notes

| Technique | Applied Where | Savings |
|-----------|---------------|---------|
| Storage packing (`uint128`/`uint64`) | Permission variables (slots 6-8) | ~2,100 gas per SLOAD saved |
| `immutable` for wstETH address | Constructor → bytecode | 2,100 → 3 gas per access |
| Custom errors | All revert paths | ~50 gas per revert vs require strings |
| `Math.mulDiv` | Yield calculation | Avoids 512-bit overflow without extra storage |
| Short-circuit returns | `getAvailableYield` exits early if no deposit or rate unchanged | Saves gas on most common view calls |
| `calldata` for arrays | `addRecipientsBatch` | Avoids memory copy |

Estimated gas per operation on Base:

| Function | Estimated Gas | Estimated Cost |
|----------|--------------|----------------|
| `deposit` (first) | ~90,000 | ~$0.05 |
| `deposit` (subsequent, re-anchor) | ~110,000 | ~$0.06 |
| `claimYield` | ~75,000 | ~$0.04 |
| `withdrawPrincipal` | ~65,000 | ~$0.03 |
| `addRecipient` | ~50,000 | ~$0.03 |
| `getAvailableYield` (view) | ~15,000 | Free |

---

## 12. Scope Boundaries

### In Scope

- `AgentTreasury.sol` — all functions described above
- `RateOracle.sol` — owner-updatable rate feed
- `IRateOracle.sol` — interface
- Foundry tests (unit, fuzz, invariant) on Base mainnet fork
- Deployment scripts for Base mainnet
- Rate update script

### Out of Scope (handled by other PRD sections)

- Agent runtime (TypeScript/Node.js)
- x402 / MPP payment protocol integration
- Frontend dashboard
- Swap contracts (wstETH → USDC)
- Factory contract
- Sub-agent yield allocation
- Chainlink oracle integration (future)

---

## 13. Acceptance Criteria

The smart contract work is complete when:

1. `AgentTreasury` and `RateOracle` compile with no warnings under `solc 0.8.24+`
2. All unit tests pass on Base mainnet fork
3. Fuzz tests (1,000+ runs) find no violations of INV-1 through INV-5
4. The following scenario succeeds end-to-end on fork:
   - Owner deploys oracle + treasury
   - Owner deposits 10 wstETH
   - Oracle rate increases (simulated via `setRate`)
   - Agent queries `getAvailableYield()` — returns > 0
   - Agent calls `claimYield(yield, whitelistedRecipient)` — succeeds
   - Agent calls `claimYield(tooMuch, recipient)` — reverts with `ExceedsAvailableYield`
   - Agent calls `claimYield(amount, nonWhitelisted)` — reverts with `RecipientNotWhitelisted`
   - Owner calls `withdrawPrincipal(all, owner)` — succeeds, gets remaining wstETH
   - Agent calls `claimYield(anything, anyone)` — reverts (no deposit)
5. Contracts deploy successfully to Base mainnet
6. Contracts verified on BaseScan
7. `forge coverage` shows ≥90% line coverage for both contracts
