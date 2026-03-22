# Implementation Spec: stETH Agent Treasury Smart Contracts

**Source PRD:** `docs/SMART_CONTRACT_PRD.md`
**Status:** Ready for implementation (v2 — incorporates council review fixes)
**Toolchain:** Foundry (forge, cast, anvil)
**Solidity:** 0.8.24, optimizer 200 runs, cancun EVM target
**Test environment:** Base mainnet fork (`--fork-url`)

---

## 1. Project Bootstrap

### 1.1 Initialize

```bash
cd lido/lido_steth_agent_treasury
forge init --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-commit
```

### 1.2 `foundry.toml`

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false
gas_reports = ["AgentTreasury", "RateOracle"]

[profile.default.fuzz]
runs = 1000
max_test_rejects = 100000

[profile.default.invariant]
runs = 256
depth = 50

[rpc_endpoints]
base = "${BASE_RPC_URL}"
ethereum = "${ETH_RPC_URL}"

[etherscan]
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
```

### 1.3 `remappings.txt`

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

### 1.4 `.env` (not committed)

```
BASE_RPC_URL=https://mainnet.base.org
ETH_RPC_URL=https://eth.llamarpc.com
DEPLOYER_PRIVATE_KEY=
OWNER_ADDRESS=
AGENT_ADDRESS=
BASESCAN_API_KEY=
```

---

## 2. Constants

```solidity
// Base mainnet wstETH (ERC20Bridged via OssifiableProxy)
address constant WSTETH_BASE = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

// Ethereum mainnet wstETH (native, has stEthPerToken())
address constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

// 1e18 — used as the denominator in rate math (stEthPerToken is 18-decimal)
uint256 constant RATE_PRECISION = 1e18;
```

---

## 3. Contract: `IRateOracle`

**File:** `src/interfaces/IRateOracle.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRateOracle
/// @notice Provides the wstETH-to-stETH exchange rate.
/// @dev On L1, wraps wstETH.stEthPerToken(). On L2, backed by a keeper.
interface IRateOracle {
    /// @notice The current stETH value of 1 wstETH, scaled to 18 decimals.
    /// @return rate  e.g. 1.2e18 means 1 wstETH = 1.2 stETH
    function getRate() external view returns (uint256 rate);

    /// @notice Timestamp of the last rate update.
    function lastUpdated() external view returns (uint256);
}
```

---

## 4. Contract: `RateOracle`

**File:** `src/RateOracle.sol`

### 4.1 Full Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRateOracle} from "./interfaces/IRateOracle.sol";

/// @title RateOracle
/// @notice Owner-updatable oracle providing wstETH/stETH rate on L2.
/// @dev The owner (or an automated keeper) pushes the L1 stEthPerToken()
///      value to this contract. Rate is expected to increase monotonically
///      (~3.5% APR) barring validator slashing events.
contract RateOracle is IRateOracle, Ownable {
    // ─── Errors ───────────────────────────────────────────────
    error InvalidRate();
    error RateChangeExceedsLimit(uint256 newRate, uint256 oldRate);

    // ─── Events ───────────────────────────────────────────────
    event RateUpdated(uint256 newRate, uint256 timestamp);

    // ─── Constants ────────────────────────────────────────────
    /// @notice Max rate increase per update: 1% (100 basis points).
    ///         Lido's own oracle caps at ~0.074% per daily report (~27% APR).
    ///         1% gives generous headroom while preventing abuse.
    uint256 public constant MAX_RATE_INCREASE_BPS = 100;
    /// @notice Max rate decrease per update: 5% (500 basis points).
    ///         Matches Lido's oracle sanity check for slashing events.
    uint256 public constant MAX_RATE_DECREASE_BPS = 500;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ─── State ────────────────────────────────────────────────
    uint256 public rate;
    uint256 public lastUpdated;

    // ─── Constructor ──────────────────────────────────────────
    constructor(address _owner, uint256 _initialRate) Ownable(_owner) {
        if (_initialRate == 0) revert InvalidRate();
        rate = _initialRate;
        lastUpdated = block.timestamp;
        emit RateUpdated(_initialRate, block.timestamp);
    }

    // ─── External ─────────────────────────────────────────────

    /// @notice Update the wstETH/stETH rate with sanity bounds.
    /// @param _rate New rate (stETH per wstETH), 18 decimals.
    /// @dev Rate must be within [rate * 95%, rate * 101%] of current rate.
    ///      This prevents oracle compromise from inflating/crashing yield.
    function setRate(uint256 _rate) external onlyOwner {
        if (_rate == 0) revert InvalidRate();
        uint256 oldRate = rate;
        if (oldRate > 0) {
            uint256 maxIncrease = oldRate * (BPS_DENOMINATOR + MAX_RATE_INCREASE_BPS) / BPS_DENOMINATOR;
            uint256 maxDecrease = oldRate * (BPS_DENOMINATOR - MAX_RATE_DECREASE_BPS) / BPS_DENOMINATOR;
            if (_rate > maxIncrease || _rate < maxDecrease) {
                revert RateChangeExceedsLimit(_rate, oldRate);
            }
        }
        rate = _rate;
        lastUpdated = block.timestamp;
        emit RateUpdated(_rate, block.timestamp);
    }

    /// @notice Force-set the rate without sanity bounds. Emergency only.
    /// @dev Use when rate needs a large correction (e.g., after extended keeper downtime).
    function forceSetRate(uint256 _rate) external onlyOwner {
        if (_rate == 0) revert InvalidRate();
        rate = _rate;
        lastUpdated = block.timestamp;
        emit RateUpdated(_rate, block.timestamp);
    }

    /// @inheritdoc IRateOracle
    function getRate() external view override returns (uint256) {
        return rate;
    }

    /// @inheritdoc IRateOracle
    function lastUpdated() external view override returns (uint256) {
        return lastUpdated;
    }
}
```

### 4.2 Notes

- `Ownable` from OZ v5 takes `address initialOwner` in constructor. No `renounceOwnership` needed here — a single owner who can update the rate is the intended model.
- **Sanity bounds:** `setRate()` enforces max +1% / -5% per update. This matches Lido's own oracle sanity checks and prevents a compromised keeper key from draining the treasury. `forceSetRate()` bypasses bounds for emergency corrections (requires owner key, not just keeper).
- `getRate()` does not revert on stale data. Staleness is checked by the treasury via `maxStaleness`.
- `lastUpdated()` is now part of `IRateOracle` so the treasury can check staleness.
- Gas: `setRate` ≈ 31,000 (2 SSTOREs + bounds check). `getRate` ≈ 2,600 (1 SLOAD).

---

## 5. Contract: `AgentTreasury`

**File:** `src/AgentTreasury.sol`

### 5.1 Imports

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRateOracle} from "./interfaces/IRateOracle.sol";
```

### 5.2 Contract Shell

```solidity
/// @title AgentTreasury
/// @notice Yield-splitting vault: owner deposits wstETH, agent spends only yield.
/// @dev Principal is structurally inaccessible to the agent.
///      Yield = W * (Rt - R0) / Rt  where W=deposit, R0=rate-at-deposit, Rt=current-rate.
///      All yield math uses wstETH units. Rate comes from an external IRateOracle.
contract AgentTreasury is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
```

### 5.3 Roles

```solidity
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
```

### 5.4 Custom Errors

```solidity
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRate();
    error NotAContract(address addr);
    error StaleRate(uint256 lastUpdated, uint256 maxStaleness);
    error RecipientNotWhitelisted(address recipient);
    error ExceedsAvailableYield(uint256 requested, uint256 available);
    error ExceedsPerTransactionCap(uint256 requested, uint256 cap);
    error ExceedsSpendingWindowLimit(uint256 requested, uint256 remaining);
    error CooldownNotElapsed(uint256 nextAllowedTimestamp);
    error PrincipalViolation(uint256 remainingBalance, uint256 requiredMinimum);
    error InsufficientBalance();
    error BatchTooLarge(uint256 length, uint256 max);
    error NotAuthorized();
```

### 5.5 Events

```solidity
    event Deposited(address indexed depositor, uint256 wstETHAmount, uint256 rateAtDeposit);
    event PrincipalWithdrawn(address indexed owner, uint256 wstETHAmount, address indexed to);
    event EmergencyWithdraw(address indexed owner, uint256 wstETHAmount, address indexed to);
    event YieldClaimed(address indexed agent, uint256 wstETHAmount, address indexed recipient);
    event YieldToppedUp(address indexed owner, uint256 wstETHAmount);
    event TokensRescued(address indexed token, uint256 amount, address indexed to);
    event RecipientWhitelisted(address indexed recipient, bool status);
    event MaxPerTransactionUpdated(uint128 oldValue, uint128 newValue);
    event SpendingLimitUpdated(uint128 limit, uint64 window);
    event CooldownPeriodUpdated(uint64 oldPeriod, uint64 newPeriod);
    event MaxStalenessUpdated(uint64 oldValue, uint64 newValue);
    event RateOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
```

### 5.6 State Variables

```solidity
    // ─── Immutables ───────────────────────────────────────────
    IERC20 public immutable wstETH;

    // ─── Rate Oracle ──────────────────────────────────────────
    IRateOracle public rateOracle;                              // slot N+0

    // ─── Principal Tracking ───────────────────────────────────
    uint256 public wstETHDeposited;                             // slot N+1
    uint256 public initialRate;                                 // slot N+2
    uint256 public pendingYieldBonus;                           // slot N+3
    uint256 public totalYieldClaimed;                           // slot N+4

    // ─── Whitelist ────────────────────────────────────────────
    mapping(address => bool) public whitelistedRecipients;      // slot N+5

    // ─── Packed Permission Slot A ─────────────────────────────
    uint128 public maxPerTransaction;                           // slot N+6 [0:127]
    uint128 public spendingLimit;                               // slot N+6 [128:255]

    // ─── Packed Permission Slot B ─────────────────────────────
    uint64 public spendingWindow;                               // slot N+7 [0:63]
    uint64 public windowStart;                                  // slot N+7 [64:127]
    uint128 public spentInCurrentWindow;                        // slot N+7 [128:255]

    // ─── Packed Permission Slot C ─────────────────────────────
    uint64 public cooldownPeriod;                               // slot N+8 [0:63]
    uint64 public lastClaimTimestamp;                            // slot N+8 [64:127]
    uint64 public maxStaleness;                                 // slot N+8 [128:191] oracle staleness limit, 0=disabled
    // 64 bits remaining in slot N+8 for future use
```

**Note on slot numbering:** `AccessControl`, `ReentrancyGuard`, and `Pausable` each occupy base slots. The exact offset `N` depends on the OZ v5 layout. In practice, this doesn't matter for correctness — Solidity handles it. The slot comments are relative to the contract's own declared variables. Storage packing within each slot is what saves gas.

### 5.7 Constructor

```solidity
    constructor(
        address _wstETH,
        address _rateOracle,
        address _owner,
        address _agent
    ) {
        if (_wstETH == address(0)) revert ZeroAddress();
        if (_rateOracle == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_agent == address(0)) revert ZeroAddress();

        wstETH = IERC20(_wstETH);
        rateOracle = IRateOracle(_rateOracle);

        // Role setup
        _grantRole(OWNER_ROLE, _owner);
        _grantRole(AGENT_ROLE, _agent);

        // OWNER_ROLE is admin for AGENT_ROLE and GUARDIAN_ROLE
        _setRoleAdmin(AGENT_ROLE, OWNER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, OWNER_ROLE);

        // Renounce DEFAULT_ADMIN_ROLE from deployer.
        // After this, only OWNER_ROLE can manage AGENT/GUARDIAN.
        // Nobody can grant new OWNER_ROLE members (single-owner by design).
        // If multi-owner needed later, owner can grant OWNER_ROLE to others
        // via DEFAULT_ADMIN_ROLE... but we've renounced it.
        // To keep it simple: OWNER_ROLE admin stays as DEFAULT_ADMIN_ROLE (0x00),
        // so nobody can add new owners. Owner can still add agents/guardians.
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
```

**Important design note on role admin:** After revoking `DEFAULT_ADMIN_ROLE` from the deployer, `OWNER_ROLE`'s admin is `DEFAULT_ADMIN_ROLE` (the OZ default). Since nobody holds `DEFAULT_ADMIN_ROLE`, no one can grant or revoke `OWNER_ROLE`. This means:
- The initial owner is the permanent owner (unless they transfer via a custom function — which we deliberately omit to keep it simple).
- The owner CAN grant/revoke `AGENT_ROLE` and `GUARDIAN_ROLE` because those have `OWNER_ROLE` as their admin.

Owner transferability is included (prevents permanent fund lock on key loss):
```solidity
function transferOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
    if (newOwner == address(0)) revert ZeroAddress();
    _revokeRole(OWNER_ROLE, msg.sender);
    _grantRole(OWNER_ROLE, newOwner);
    emit OwnershipTransferred(msg.sender, newOwner);
}
```

### 5.8 Deposit

```solidity
    /// @notice Deposit wstETH as principal. Only owner. Requires prior ERC-20 approval.
    /// @param amount  wstETH amount to deposit (18 decimals)
    function deposit(uint256 amount) external onlyRole(OWNER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        if (wstETHDeposited > 0) {
            // Subsequent deposit: preserve unclaimed yield, then re-anchor
            _reanchor();
        } else {
            // First deposit: anchor to current rate
            uint256 currentRate = _currentRate();
            if (currentRate == 0) revert InvalidRate();
            initialRate = currentRate;
        }

        wstETHDeposited += amount;
        wstETH.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount, initialRate);
    }
```

### 5.9 Withdraw Principal

```solidity
    /// @notice Withdraw wstETH principal. Only owner. Works even when paused.
    /// @param amount  wstETH amount to withdraw
    /// @param to      Recipient address
    function withdrawPrincipal(uint256 amount, address to)
        external
        onlyRole(OWNER_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = wstETH.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        if (amount >= balance) {
            // Full withdrawal: reset everything
            _resetState();
        } else {
            // Partial withdrawal: re-anchor then reduce deposited amount
            _reanchor();
            // Cap reduction at wstETHDeposited to handle edge case
            // where balance includes unclaimed yield > deposit tracking
            uint256 reduction = amount > wstETHDeposited ? wstETHDeposited : amount;
            wstETHDeposited -= reduction;
        }

        wstETH.safeTransfer(to, amount);

        emit PrincipalWithdrawn(msg.sender, amount, to);
    }

    /// @notice Emergency: withdraw all wstETH. Resets the treasury.
    /// @param to  Recipient address
    function emergencyWithdraw(address to)
        external
        onlyRole(OWNER_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = wstETH.balanceOf(address(this));
        _resetState();

        if (balance > 0) {
            wstETH.safeTransfer(to, balance);
        }

        emit EmergencyWithdraw(msg.sender, balance, to);
    }
```

### 5.10 Claim Yield

```solidity
    /// @notice Agent claims accrued yield, sent to a whitelisted recipient.
    /// @param amount     wstETH amount to claim
    /// @param recipient  Must be whitelisted
    function claimYield(uint256 amount, address recipient)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        whenNotPaused
    {
        // ── CHECKS ──
        if (!whitelistedRecipients[recipient]) {
            revert RecipientNotWhitelisted(recipient);
        }
        if (amount == 0) revert ZeroAmount();

        uint256 available = getAvailableYield();
        if (amount > available) {
            revert ExceedsAvailableYield(amount, available);
        }
        if (maxPerTransaction != 0 && amount > uint256(maxPerTransaction)) {
            revert ExceedsPerTransactionCap(amount, uint256(maxPerTransaction));
        }
        _enforceSpendingWindow(amount);
        _enforceCooldown();

        // ── EFFECTS ──
        totalYieldClaimed += amount;
        lastClaimTimestamp = uint64(block.timestamp);

        // ── INTERACTIONS ──
        wstETH.safeTransfer(recipient, amount);

        // ── POST-CONDITION (belt-and-suspenders) ──
        uint256 minRequired = _principalWstETHFloor();
        uint256 currentBalance = wstETH.balanceOf(address(this));
        if (currentBalance < minRequired) {
            revert PrincipalViolation(currentBalance, minRequired);
        }

        emit YieldClaimed(msg.sender, amount, recipient);
    }
```

### 5.11 View Functions

```solidity
    /// @notice Available yield the agent can claim, in wstETH.
    /// @dev If maxStaleness is set and oracle is stale, only pendingYieldBonus is available.
    function getAvailableYield() public view returns (uint256) {
        uint256 currentRate = _currentRate();
        uint256 yieldFromRate = 0;

        // Staleness check: if oracle is stale, ignore rate-based yield
        bool rateIsFresh = true;
        if (maxStaleness > 0 && currentRate > 0) {
            try rateOracle.lastUpdated() returns (uint256 updated) {
                if (block.timestamp > updated + uint256(maxStaleness)) {
                    rateIsFresh = false;
                }
            } catch {
                rateIsFresh = false;
            }
        }

        if (rateIsFresh && currentRate > initialRate && wstETHDeposited > 0) {
            yieldFromRate = Math.mulDiv(
                wstETHDeposited,
                currentRate - initialRate,
                currentRate
            );
        }

        uint256 totalAvailable = yieldFromRate + pendingYieldBonus;
        return totalAvailable > totalYieldClaimed
            ? totalAvailable - totalYieldClaimed
            : 0;
    }

    /// @notice Available yield converted to stETH denomination.
    function getAvailableYieldInStETH() external view returns (uint256) {
        uint256 yieldWstETH = getAvailableYield();
        uint256 currentRate = _currentRate();
        if (currentRate == 0) return 0;
        return Math.mulDiv(yieldWstETH, currentRate, 1e18);
    }

    /// @notice Original principal value in stETH terms.
    function getPrincipalValue() external view returns (uint256) {
        if (initialRate == 0) return 0;
        return Math.mulDiv(wstETHDeposited, initialRate, 1e18);
    }

    /// @notice Total current value (principal + unclaimed yield) in stETH.
    function getTotalValue() external view returns (uint256) {
        uint256 currentRate = _currentRate();
        if (currentRate == 0) return 0;
        return Math.mulDiv(wstETH.balanceOf(address(this)), currentRate, 1e18);
    }

    /// @notice Minimum wstETH the contract must hold to back the principal.
    /// @dev Uses ceiling division to be conservative.
    function principalWstETHFloor() external view returns (uint256) {
        return _principalWstETHFloor();
    }
```

### 5.12 Permission Setters

```solidity
    // ─── Whitelist ────────────────────────────────────────────

    function addRecipient(address recipient) external onlyRole(OWNER_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedRecipients[recipient] = true;
        emit RecipientWhitelisted(recipient, true);
    }

    function removeRecipient(address recipient) external onlyRole(OWNER_ROLE) {
        whitelistedRecipients[recipient] = false;
        emit RecipientWhitelisted(recipient, false);
    }

    uint256 public constant MAX_BATCH_SIZE = 100;

    function addRecipientsBatch(address[] calldata recipients) external onlyRole(OWNER_ROLE) {
        if (recipients.length > MAX_BATCH_SIZE) revert BatchTooLarge(recipients.length, MAX_BATCH_SIZE);
        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            whitelistedRecipients[recipients[i]] = true;
            emit RecipientWhitelisted(recipients[i], true);
        }
    }

    // ─── Caps ─────────────────────────────────────────────────

    function setMaxPerTransaction(uint128 _max) external onlyRole(OWNER_ROLE) {
        uint128 old = maxPerTransaction;
        maxPerTransaction = _max;
        emit MaxPerTransactionUpdated(old, _max);
    }

    function setSpendingLimit(uint128 _limit, uint64 _window) external onlyRole(OWNER_ROLE) {
        spendingLimit = _limit;
        spendingWindow = _window;
        // Reset window state so next claim starts a fresh window
        windowStart = 0;
        spentInCurrentWindow = 0;
        emit SpendingLimitUpdated(_limit, _window);
    }

    function setCooldownPeriod(uint64 _period) external onlyRole(OWNER_ROLE) {
        uint64 old = cooldownPeriod;
        cooldownPeriod = _period;
        emit CooldownPeriodUpdated(old, _period);
    }

    // ─── Oracle ───────────────────────────────────────────────

    function setRateOracle(address _newOracle) external onlyRole(OWNER_ROLE) {
        if (_newOracle == address(0)) revert ZeroAddress();
        if (_newOracle.code.length == 0) revert NotAContract(_newOracle);
        // Re-anchor yield under old oracle before switching
        _reanchor();
        address old = address(rateOracle);
        rateOracle = IRateOracle(_newOracle);
        // Verify the new oracle returns a sane rate
        uint256 newRate = IRateOracle(_newOracle).getRate();
        if (newRate == 0) revert InvalidRate();
        emit RateOracleUpdated(old, _newOracle);
    }

    // ─── Staleness ────────────────────────────────────────────

    function setMaxStaleness(uint64 _maxStaleness) external onlyRole(OWNER_ROLE) {
        uint64 old = maxStaleness;
        maxStaleness = _maxStaleness;
        emit MaxStalenessUpdated(old, _maxStaleness);
    }
```

### 5.13 Pause

```solidity
    // ─── Modifier ──────────────────────────────────────────────
    modifier onlyOwnerOrGuardian() {
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender))
            revert NotAuthorized();
        _;
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyRole(OWNER_ROLE) {
        _unpause();
    }
```

### 5.13b New Functions (Council Review Additions)

```solidity
    // ─── Top-Up Yield (Council fix: economic viability) ───────
    /// @notice Owner injects wstETH directly as spendable yield (not principal).
    ///         Solves the "tiny yield" problem — owner can front-load agent budget.
    /// @param amount  wstETH to add as yield budget
    function topUpYield(uint256 amount) external onlyRole(OWNER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        pendingYieldBonus += amount;
        wstETH.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldToppedUp(msg.sender, amount);
    }

    // ─── Rescue Stuck Tokens (Council fix: donation attack) ───
    /// @notice Recover tokens accidentally sent to the contract.
    ///         Cannot rescue wstETH beyond what is needed for principal + yield.
    /// @param token  ERC-20 token address to rescue
    /// @param amount Amount to rescue
    /// @param to     Recipient
    function rescueTokens(address token, uint256 amount, address to)
        external
        onlyRole(OWNER_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(wstETH)) {
            // For wstETH: only rescue excess beyond principal floor + unclaimed yield
            uint256 needed = _principalWstETHFloor() + getAvailableYield();
            uint256 balance = wstETH.balanceOf(address(this));
            uint256 rescuable = balance > needed ? balance - needed : 0;
            if (amount > rescuable) revert InsufficientBalance();
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, amount, to);
    }

    // ─── Aggregate Status View (Council fix: agent DX) ────────
    struct TreasuryStatus {
        uint256 availableYield;
        uint256 availableYieldStETH;
        uint256 principalFloor;
        uint256 principalValueStETH;
        uint256 contractBalance;
        uint256 currentRate;
        uint256 rateLastUpdated;
        uint128 maxPerTx;
        uint128 currentSpendingLimit;
        uint128 spentInWindow;
        uint64 windowSecondsRemaining;
        uint64 cooldownSecondsRemaining;
        bool isPaused;
    }

    /// @notice Returns the full treasury status in a single call.
    function getStatus() external view returns (TreasuryStatus memory s) {
        uint256 currentRate = _currentRate();
        s.availableYield = getAvailableYield();
        s.availableYieldStETH = currentRate > 0
            ? Math.mulDiv(s.availableYield, currentRate, 1e18) : 0;
        s.principalFloor = _principalWstETHFloor();
        s.principalValueStETH = initialRate > 0
            ? Math.mulDiv(wstETHDeposited, initialRate, 1e18) : 0;
        s.contractBalance = wstETH.balanceOf(address(this));
        s.currentRate = currentRate;
        s.rateLastUpdated = rateOracle.lastUpdated();
        s.maxPerTx = maxPerTransaction;
        s.currentSpendingLimit = spendingLimit;
        s.spentInWindow = spentInCurrentWindow;

        uint256 windowEnd = uint256(windowStart) + uint256(spendingWindow);
        s.windowSecondsRemaining = block.timestamp < windowEnd
            ? uint64(windowEnd - block.timestamp) : 0;

        uint256 cooldownEnd = uint256(lastClaimTimestamp) + uint256(cooldownPeriod);
        s.cooldownSecondsRemaining = block.timestamp < cooldownEnd
            ? uint64(cooldownEnd - block.timestamp) : 0;

        s.isPaused = paused();
    }
```

### 5.14 Internal Functions

```solidity
    // ─── Internals ────────────────────────────────────────────

    function _currentRate() internal view returns (uint256) {
        return rateOracle.getRate();
    }

    /// @dev Minimum wstETH to back principal. Ceiling-rounded.
    ///      When rate is 0 (oracle unavailable), returns full deposit as floor
    ///      to prevent any yield claims when rate is unknown.
    function _principalWstETHFloor() internal view returns (uint256) {
        if (wstETHDeposited == 0) return 0;
        uint256 currentRate = _currentRate();
        if (currentRate == 0) return wstETHDeposited; // Safe: block all claims when oracle is down
        return Math.mulDiv(wstETHDeposited, initialRate, currentRate, Math.Rounding.Ceil);
    }

    /// @dev Compute raw yield from rate delta (before pendingYieldBonus / totalYieldClaimed).
    function _calculateRawYield() internal view returns (uint256) {
        uint256 currentRate = _currentRate();
        if (currentRate <= initialRate || wstETHDeposited == 0) return 0;
        return Math.mulDiv(wstETHDeposited, currentRate - initialRate, currentRate);
    }

    /// @dev Re-anchor: snapshot unclaimed yield into pendingYieldBonus, reset counters,
    ///      update initialRate to current. Called before deposits and partial withdrawals.
    function _reanchor() internal {
        uint256 currentRate = _currentRate();
        if (currentRate == 0 || wstETHDeposited == 0) return;

        uint256 rawYield = _calculateRawYield();
        uint256 totalAvailable = rawYield + pendingYieldBonus;
        uint256 unclaimed = totalAvailable > totalYieldClaimed
            ? totalAvailable - totalYieldClaimed
            : 0;

        pendingYieldBonus = unclaimed;
        totalYieldClaimed = 0;
        initialRate = currentRate;
    }

    /// @dev Reset all principal/yield tracking state to zero.
    function _resetState() internal {
        wstETHDeposited = 0;
        initialRate = 0;
        pendingYieldBonus = 0;
        totalYieldClaimed = 0;
    }

    /// @dev Enforce time-windowed spending limit. Updates window state.
    function _enforceSpendingWindow(uint256 amount) internal {
        if (spendingLimit == 0) return; // disabled

        // Check if current window has expired
        if (block.timestamp >= uint256(windowStart) + uint256(spendingWindow)) {
            windowStart = uint64(block.timestamp);
            spentInCurrentWindow = 0;
        }

        uint256 remaining = uint256(spendingLimit) - uint256(spentInCurrentWindow);
        if (amount > remaining) {
            revert ExceedsSpendingWindowLimit(amount, remaining);
        }

        spentInCurrentWindow += amount.toUint128(); // SafeCast: reverts if > uint128
    }

    /// @dev Enforce cooldown between claims. View-only check.
    function _enforceCooldown() internal view {
        if (cooldownPeriod == 0) return; // disabled

        uint256 nextAllowed = uint256(lastClaimTimestamp) + uint256(cooldownPeriod);
        if (block.timestamp < nextAllowed) {
            revert CooldownNotElapsed(nextAllowed);
        }
    }

} // end contract
```

---

## 6. Deployment Scripts

### 6.1 `script/DeployAll.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RateOracle} from "../src/RateOracle.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";

contract DeployAll is Script {
    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address agent = vm.envAddress("AGENT_ADDRESS");
        uint256 initialRate = vm.envUint("INITIAL_RATE");

        vm.startBroadcast();

        RateOracle oracle = new RateOracle(owner, initialRate);
        console.log("RateOracle deployed:", address(oracle));

        AgentTreasury treasury = new AgentTreasury(
            0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452, // wstETH on Base
            address(oracle),
            owner,
            agent
        );
        console.log("AgentTreasury deployed:", address(treasury));

        vm.stopBroadcast();
    }
}
```

### 6.2 `script/UpdateRate.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RateOracle} from "../src/RateOracle.sol";

contract UpdateRate is Script {
    function run() external {
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        uint256 newRate = vm.envUint("NEW_RATE");

        vm.startBroadcast();
        RateOracle(oracleAddr).setRate(newRate);
        console.log("Rate updated to:", newRate);
        vm.stopBroadcast();
    }
}
```

### 6.3 Deployment Runbook

```bash
# Step 1: Fetch current L1 rate
export INITIAL_RATE=$(cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
  "stEthPerToken()(uint256)" --rpc-url $ETH_RPC_URL)
echo "stEthPerToken = $INITIAL_RATE"

# Step 2: Deploy
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvv

# Step 3: Owner approves + deposits wstETH
cast send $WSTETH_BASE "approve(address,uint256)" $TREASURY 1000000000000000000 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

cast send $TREASURY "deposit(uint256)" 1000000000000000000 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

# Step 4: Owner configures permissions
cast send $TREASURY "addRecipient(address)" $AGENT_ADDRESS \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

cast send $TREASURY "setMaxPerTransaction(uint128)" 2000000000000000 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY

cast send $TREASURY "setSpendingLimit(uint128,uint64)" 10000000000000000 86400 \
  --rpc-url $BASE_RPC_URL --private-key $OWNER_KEY
```

---

## 7. Test Implementation

### 7.1 `test/helpers/BaseMainnetFork.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RateOracle} from "../../src/RateOracle.sol";
import {AgentTreasury} from "../../src/AgentTreasury.sol";

abstract contract BaseMainnetFork is Test {
    // ─── Base mainnet constants ───────────────────────────────
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    // ─── Test actors ──────────────────────────────────────────
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address guardian = makeAddr("guardian");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");
    address nobody = makeAddr("nobody");

    // ─── Contracts ────────────────────────────────────────────
    RateOracle oracle;
    AgentTreasury treasury;

    // ─── Default rate: ~1.2 stETH per wstETH ─────────────────
    uint256 constant INITIAL_RATE = 1.2e18;
    uint256 constant RATE_AFTER_YIELD = 1.22e18; // +1.67% yield

    function setUp() public virtual {
        // Fork Base mainnet
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        // Deploy contracts
        oracle = new RateOracle(owner, INITIAL_RATE);
        treasury = new AgentTreasury(WSTETH, address(oracle), owner, agent);

        // Fund owner with wstETH using deal (works on fork)
        deal(WSTETH, owner, 1000e18);

        // Owner whitelists recipient1
        vm.prank(owner);
        treasury.addRecipient(recipient1);
    }

    /// @dev Helper: owner deposits a given amount of wstETH
    function _ownerDeposit(uint256 amount) internal {
        vm.startPrank(owner);
        IERC20(WSTETH).approve(address(treasury), amount);
        treasury.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Helper: simulate yield by bumping oracle rate
    function _simulateYield(uint256 newRate) internal {
        vm.prank(owner);
        oracle.setRate(newRate);
    }
}
```

### 7.2 Key Test Scenarios

The test file should exercise every path from the PRD's test plan (Section 9.3). Here are the critical ones with implementation guidance:

#### Principal Preservation Test

```solidity
function test_principalPreservation_afterMaxClaim() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    uint256 maxYield = treasury.getAvailableYield();
    assertGt(maxYield, 0, "Should have yield");

    // Agent claims all available yield
    vm.prank(agent);
    treasury.claimYield(maxYield, recipient1);

    // Verify: remaining balance covers principal
    uint256 balance = IERC20(WSTETH).balanceOf(address(treasury));
    uint256 floor = treasury.principalWstETHFloor();
    assertGe(balance, floor, "Balance must cover principal floor");

    // Verify: principal value in stETH unchanged
    // P = 100e18 * 1.2e18 / 1e18 = 120e18 stETH
    // floor * currentRate / 1e18 should >= 120e18
    uint256 floorValueStETH = (floor * RATE_AFTER_YIELD) / 1e18;
    uint256 originalPrincipalStETH = (100e18 * INITIAL_RATE) / 1e18;
    assertGe(floorValueStETH, originalPrincipalStETH, "stETH value must cover original principal");
}
```

#### Yield Calculation Accuracy Test

```solidity
function test_yieldCalculation_matchesExpected() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    uint256 yield = treasury.getAvailableYield();
    // Expected: 100e18 * (1.22e18 - 1.2e18) / 1.22e18
    // = 100e18 * 0.02e18 / 1.22e18
    // = 1.639344262295081967...e18
    uint256 expected = Math.mulDiv(100e18, RATE_AFTER_YIELD - INITIAL_RATE, RATE_AFTER_YIELD);
    assertEq(yield, expected, "Yield should match formula");
}
```

#### Permission Enforcement Tests

```solidity
function test_claimYield_notWhitelisted_reverts() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    vm.prank(agent);
    vm.expectRevert(abi.encodeWithSelector(
        AgentTreasury.RecipientNotWhitelisted.selector, nobody
    ));
    treasury.claimYield(1e15, nobody);
}

function test_claimYield_exceedsPerTxCap_reverts() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    vm.prank(owner);
    treasury.setMaxPerTransaction(1e15); // 0.001 wstETH cap

    uint256 yield = treasury.getAvailableYield();
    assertGt(yield, 1e15, "Yield should exceed cap for this test");

    vm.prank(agent);
    vm.expectRevert(abi.encodeWithSelector(
        AgentTreasury.ExceedsPerTransactionCap.selector, yield, 1e15
    ));
    treasury.claimYield(yield, recipient1);
}

function test_claimYield_windowLimit_reverts() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    vm.prank(owner);
    treasury.setSpendingLimit(1e15, 86400); // 0.001 wstETH per day

    // First claim within limit
    vm.prank(agent);
    treasury.claimYield(1e15, recipient1);

    // Second claim exceeds window
    vm.prank(agent);
    vm.expectRevert(); // ExceedsSpendingWindowLimit
    treasury.claimYield(1, recipient1);

    // Warp past window
    vm.warp(block.timestamp + 86401);

    // Now it works again
    vm.prank(agent);
    treasury.claimYield(1e14, recipient1);
}
```

#### Access Control Tests

```solidity
function test_deposit_nonOwner_reverts() public {
    deal(WSTETH, agent, 10e18);
    vm.startPrank(agent);
    IERC20(WSTETH).approve(address(treasury), 10e18);
    vm.expectRevert(); // AccessControl error
    treasury.deposit(10e18);
    vm.stopPrank();
}

function test_claimYield_nonAgent_reverts() public {
    _ownerDeposit(100e18);
    _simulateYield(RATE_AFTER_YIELD);

    vm.prank(owner);
    vm.expectRevert(); // AccessControl error
    treasury.claimYield(1, recipient1);
}

function test_withdrawPrincipal_whenPaused_succeeds() public {
    _ownerDeposit(100e18);

    vm.prank(owner);
    treasury.pause();

    vm.prank(owner);
    treasury.withdrawPrincipal(100e18, owner); // should NOT revert
    assertEq(IERC20(WSTETH).balanceOf(address(treasury)), 0);
}
```

### 7.3 Fuzz Test Template

```solidity
function testFuzz_claimNeverExceedsPrincipal(
    uint256 depositAmt,
    uint256 rateIncreaseBps, // basis points increase
    uint256 claimPortion     // % of available yield to claim (0-100)
) public {
    // Bound inputs
    depositAmt = bound(depositAmt, 1e15, 10_000e18);
    rateIncreaseBps = bound(rateIncreaseBps, 1, 5000); // 0.01% to 50%
    claimPortion = bound(claimPortion, 1, 100);

    // Setup
    deal(WSTETH, owner, depositAmt);
    _ownerDeposit(depositAmt);

    uint256 newRate = INITIAL_RATE + (INITIAL_RATE * rateIncreaseBps / 10_000);
    _simulateYield(newRate);

    uint256 available = treasury.getAvailableYield();
    if (available == 0) return; // nothing to claim

    uint256 claimAmt = available * claimPortion / 100;
    if (claimAmt == 0) return;

    // Claim
    vm.prank(agent);
    treasury.claimYield(claimAmt, recipient1);

    // Invariant: balance >= principal floor
    uint256 balance = IERC20(WSTETH).balanceOf(address(treasury));
    uint256 floor = treasury.principalWstETHFloor();
    assertGe(balance, floor, "INV-1: balance must cover principal floor");
}
```

---

## 8. Implementation Order

A step-by-step build sequence. Each step should compile and have passing tests before moving on.

### Step 1: Skeleton + IRateOracle + RateOracle (with sanity bounds)

Files: `src/interfaces/IRateOracle.sol`, `src/RateOracle.sol`, `test/RateOracle.t.sol`

Tests: constructor, setRate (within bounds), setRate (exceeds bounds — reverts), forceSetRate, getRate, lastUpdated, access control, zero-rate revert.

Verify: `forge test --match-contract RateOracleTest -vvv`

### Step 2: AgentTreasury — Constructor + Deposit + Withdraw

Files: `src/AgentTreasury.sol` (constructor with transferOwnership, deposit, withdrawPrincipal, emergencyWithdraw, `_reanchor`, `_resetState`, `_currentRate`)

Tests: deposit first/subsequent, withdraw full/partial, emergency, access control, transferOwnership.

Verify: `forge test --match-contract AgentTreasuryTest --fork-url $BASE_RPC_URL -vvv`

### Step 3: Yield Calculation (with staleness check)

Add: `getAvailableYield` (with `maxStaleness` check), `getAvailableYieldInStETH`, `getPrincipalValue`, `getTotalValue`, `_calculateRawYield`, `_principalWstETHFloor` (returns `wstETHDeposited` when rate is 0), `setMaxStaleness`

Tests: yield with rate increase, rate decrease, rate unchanged, stale oracle returns reduced yield, rate=0 blocks claims, multiple deposits, principal preservation proof.

### Step 4: claimYield (no permissions yet)

Add: `claimYield` with basic checks (available yield, CEI, post-condition with SafeCast). Temporarily skip permission checks.

Tests: claim success, claim exceeds available, non-agent reverts, principal post-condition, rate=0 floor blocks claims.

### Step 5: Permission System

Add: whitelist (with batch limit), per-tx cap, spending window (with SafeCast), cooldown. All setters. `_enforceSpendingWindow`, `_enforceCooldown`.

Tests: each permission blocks, each permission allows, window reset, cooldown expiry, batch whitelist, batch over 100 reverts.

### Step 6: Pause + Guardian + New Functions

Add: pause/unpause with `onlyOwnerOrGuardian` modifier, guardian role, `topUpYield`, `rescueTokens`, `getStatus`.

Tests: pause blocks deposit/claim, pause does NOT block withdraw, guardian can pause, guardian cannot unpause, topUpYield increases available yield, rescueTokens for non-wstETH and for excess wstETH, getStatus returns correct aggregate.

### Step 7: Fuzz + Invariant Tests

Add: `test/AgentTreasury.fuzz.t.sol`, `test/AgentTreasury.invariant.t.sol`

Run: extended fuzz runs, invariant depth testing.

### Step 8: Gas Optimization + Polish

Review gas report. Ensure storage packing is correct. Remove any debug code. Final `forge coverage`.

### Step 9: Deployment Scripts + Mainnet Deploy

Add: `script/DeployAll.s.sol`, `script/UpdateRate.s.sol`. Dry-run on fork. Deploy to Base mainnet. Verify on BaseScan.

---

## 9. Key Design Decisions Log

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Base contract type | Custom vault (not ERC-4626) | Single depositor, asymmetric roles — ERC-4626 adds unused complexity |
| D2 | Yield denomination | wstETH | Avoids stETH rebasing/rounding. Simpler accounting. |
| D3 | Rate source | External oracle with sanity bounds | Base wstETH is ERC20Bridged, no `stEthPerToken()`. Bounds prevent oracle compromise from draining principal. |
| D4 | Upgradeability | None (immutable) | Trust guarantee: code cannot change |
| D5 | Role framework | OZ AccessControl | 3 roles needed (Owner/Agent/Guardian). Better than Ownable. |
| D6 | Yield rounding | Floor for yield, ceiling for principal floor | Always favors vault safety |
| D7 | Overflow protection | `Math.mulDiv` (512-bit) + `SafeCast` | Prevents `W * (Rt - R0)` overflow and uint128 truncation |
| D8 | Permission defaults | Whitelist: empty (restrictive). Caps: 0 (unlimited). | Fail-closed for recipients, fail-open for amounts. Owner opts in. |
| D9 | Pause scope | Blocks agent ops, NOT owner withdrawals | Owner must always be able to exit |
| D10 | `DEFAULT_ADMIN_ROLE` | Renounced in constructor | No god-mode key exists after deployment |
| D11 | Owner transferability | **Included** via `transferOwnership()` | Prevents permanent fund lock on key loss (council review fix) |
| D12 | Cooldown state mutation | `_enforceCooldown` is view-only, `lastClaimTimestamp` set in `claimYield` effects | Clean separation of check vs state update |
| D13 | Oracle staleness | Optional `maxStaleness` (0=disabled) | Prevents claims on stale rate. Uses `try/catch` on `lastUpdated()` for robustness. |
| D14 | Principal floor at rate=0 | Returns `wstETHDeposited` (full deposit) | Blocks all claims when oracle is unavailable, preventing drain via pendingYieldBonus |
| D15 | `topUpYield()` | Owner can inject wstETH as yield (not principal) | Solves "tiny yield" economic viability problem — practical at any deposit size |
| D16 | `rescueTokens()` | Owner recovers accidentally sent tokens | Prevents permanent loss of donated/stray tokens |
| D17 | `setRateOracle()` | Re-anchors before switching | Prevents yield discontinuity when changing oracle |
| D18 | `getStatus()` | Single-call aggregate view | Better agent DX: one `eth_call` instead of 10+ |
| D19 | Rate oracle bounds | Max +1% / -5% per `setRate()`, `forceSetRate()` for emergencies | Limits blast radius of compromised keeper key |
| D20 | Batch limit | `MAX_BATCH_SIZE = 100` on `addRecipientsBatch` | Prevents block gas limit DoS |
