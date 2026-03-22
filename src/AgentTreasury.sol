// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal Chainlink AggregatorV3 interface.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title AgentTreasury
/// @notice Yield-splitting vault: owner deposits wstETH, agent spends only yield.
/// @dev Principal is structurally inaccessible to the agent.
///      Yield = W * (Rt - R0) / Rt  where W=deposit, R0=rate-at-deposit, Rt=current-rate.
///      Rate comes from a Chainlink wstETH/stETH exchange rate feed (18 decimals).
///      On Base: 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061 (24h heartbeat, 10 operators).
contract AgentTreasury is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // ─── Errors ───────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRate();
    error RecipientNotWhitelisted(address recipient);
    error ExceedsAvailableYield(uint256 requested, uint256 available);
    error ExceedsPerTransactionCap(uint256 requested, uint256 cap);
    error PrincipalViolation(uint256 remainingBalance, uint256 requiredMinimum);
    error InsufficientBalance();
    error FeedDecimalsMismatch(uint8 expected, uint8 actual);

    // ─── Events ───────────────────────────────────────────────
    event Deposited(address indexed depositor, uint256 wstETHAmount, uint256 rateAtDeposit);
    event PrincipalWithdrawn(address indexed owner, uint256 wstETHAmount, address indexed to);
    event YieldClaimed(address indexed agent, uint256 wstETHAmount, address indexed recipient);
    event YieldToppedUp(address indexed owner, uint256 wstETHAmount);
    event RecipientWhitelisted(address indexed recipient, bool status);
    event MaxPerTransactionUpdated(uint128 oldValue, uint128 newValue);

    // ─── Immutables ───────────────────────────────────────────
    IERC20 public immutable wstETH;
    AggregatorV3Interface public immutable priceFeed;

    // ─── State ────────────────────────────────────────────────
    uint256 public wstETHDeposited;
    uint256 public initialRate;
    uint256 public pendingYieldBonus;
    uint256 public totalYieldClaimed;
    mapping(address => bool) public whitelistedRecipients;
    uint128 public maxPerTransaction; // 0 = unlimited

    // ─── Constructor ──────────────────────────────────────────

    /// @param _wstETH    wstETH token address (ERC-20)
    /// @param _priceFeed Chainlink AggregatorV3 for wstETH/stETH rate (must be 18 decimals)
    /// @param _owner     Human wallet that controls principal and permissions
    /// @param _agent     AI agent wallet that can spend yield
    constructor(address _wstETH, address _priceFeed, address _owner, address _agent) {
        if (_wstETH == address(0) || _priceFeed == address(0)) revert ZeroAddress();
        if (_owner == address(0) || _agent == address(0)) revert ZeroAddress();

        // Verify the feed is 18 decimals (matches our yield math)
        uint8 dec = AggregatorV3Interface(_priceFeed).decimals();
        if (dec != 18) revert FeedDecimalsMismatch(18, dec);

        wstETH = IERC20(_wstETH);
        priceFeed = AggregatorV3Interface(_priceFeed);

        _grantRole(OWNER_ROLE, _owner);
        _grantRole(AGENT_ROLE, _agent);
        _setRoleAdmin(AGENT_ROLE, OWNER_ROLE);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  DEPOSIT
    // ═══════════════════════════════════════════════════════════

    /// @notice Deposit wstETH as principal. Requires prior ERC-20 approval.
    function deposit(uint256 amount) external onlyRole(OWNER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        if (wstETHDeposited > 0) {
            _reanchor();
        } else {
            uint256 rate = _currentRate();
            if (rate == 0) revert InvalidRate();
            initialRate = rate;
        }

        wstETHDeposited += amount;
        wstETH.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, initialRate);
    }

    /// @notice Owner injects wstETH directly as spendable yield (not principal).
    function topUpYield(uint256 amount) external onlyRole(OWNER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        pendingYieldBonus += amount;
        wstETH.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldToppedUp(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  WITHDRAW
    // ═══════════════════════════════════════════════════════════

    /// @notice Withdraw wstETH. Works even when paused.
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
            // Full withdrawal — reset all state
            wstETHDeposited = 0;
            initialRate = 0;
            pendingYieldBonus = 0;
            totalYieldClaimed = 0;
        } else {
            // Partial — snapshot yield then reduce principal
            _reanchor();
            uint256 reduction = amount > wstETHDeposited ? wstETHDeposited : amount;
            wstETHDeposited -= reduction;
        }

        wstETH.safeTransfer(to, amount);
        emit PrincipalWithdrawn(msg.sender, amount, to);
    }

    // ═══════════════════════════════════════════════════════════
    //  CLAIM YIELD
    // ═══════════════════════════════════════════════════════════

    /// @notice Agent claims accrued yield to a whitelisted recipient.
    function claimYield(uint256 amount, address recipient)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        whenNotPaused
    {
        // Checks
        if (!whitelistedRecipients[recipient]) revert RecipientNotWhitelisted(recipient);
        if (amount == 0) revert ZeroAmount();

        uint256 available = getAvailableYield();
        if (amount > available) revert ExceedsAvailableYield(amount, available);
        if (maxPerTransaction != 0 && amount > uint256(maxPerTransaction)) {
            revert ExceedsPerTransactionCap(amount, uint256(maxPerTransaction));
        }

        // Effects
        totalYieldClaimed += amount;

        // Interactions
        wstETH.safeTransfer(recipient, amount);

        // Post-condition: principal must remain backed
        uint256 floor = _principalWstETHFloor();
        uint256 bal = wstETH.balanceOf(address(this));
        if (bal < floor) revert PrincipalViolation(bal, floor);

        emit YieldClaimed(msg.sender, amount, recipient);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Available yield the agent can claim (wstETH).
    function getAvailableYield() public view returns (uint256) {
        uint256 rate = _currentRate();
        uint256 yieldFromRate = 0;

        if (rate > initialRate && wstETHDeposited > 0) {
            yieldFromRate = Math.mulDiv(wstETHDeposited, rate - initialRate, rate);
        }

        uint256 total = yieldFromRate + pendingYieldBonus;
        return total > totalYieldClaimed ? total - totalYieldClaimed : 0;
    }

    /// @notice Available yield in stETH terms.
    function getAvailableYieldInStETH() external view returns (uint256) {
        uint256 rate = _currentRate();
        if (rate == 0) return 0;
        return Math.mulDiv(getAvailableYield(), rate, 1e18);
    }

    /// @notice Original principal value in stETH terms.
    function getPrincipalValue() external view returns (uint256) {
        if (initialRate == 0) return 0;
        return Math.mulDiv(wstETHDeposited, initialRate, 1e18);
    }

    /// @notice Total current value in stETH (principal + unclaimed yield).
    function getTotalValue() external view returns (uint256) {
        uint256 rate = _currentRate();
        if (rate == 0) return 0;
        return Math.mulDiv(wstETH.balanceOf(address(this)), rate, 1e18);
    }

    /// @notice Minimum wstETH the contract must hold to back the principal.
    function principalWstETHFloor() external view returns (uint256) {
        return _principalWstETHFloor();
    }

    struct TreasuryStatus {
        uint256 availableYield;
        uint256 availableYieldStETH;
        uint256 principalValueStETH;
        uint256 principalFloor;
        uint256 contractBalance;
        uint256 currentRate;
        uint128 maxPerTx;
        bool isPaused;
    }

    /// @notice Full treasury status in a single call.
    function getStatus() external view returns (TreasuryStatus memory s) {
        s.currentRate = _currentRate();
        s.availableYield = getAvailableYield();
        s.availableYieldStETH = s.currentRate > 0
            ? Math.mulDiv(s.availableYield, s.currentRate, 1e18) : 0;
        s.principalValueStETH = initialRate > 0
            ? Math.mulDiv(wstETHDeposited, initialRate, 1e18) : 0;
        s.principalFloor = _principalWstETHFloor();
        s.contractBalance = wstETH.balanceOf(address(this));
        s.maxPerTx = maxPerTransaction;
        s.isPaused = paused();
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN (Owner only)
    // ═══════════════════════════════════════════════════════════

    function addRecipient(address recipient) external onlyRole(OWNER_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedRecipients[recipient] = true;
        emit RecipientWhitelisted(recipient, true);
    }

    function removeRecipient(address recipient) external onlyRole(OWNER_ROLE) {
        whitelistedRecipients[recipient] = false;
        emit RecipientWhitelisted(recipient, false);
    }

    function setMaxPerTransaction(uint128 _max) external onlyRole(OWNER_ROLE) {
        uint128 old = maxPerTransaction;
        maxPerTransaction = _max;
        emit MaxPerTransactionUpdated(old, _max);
    }

    function pause() external onlyRole(OWNER_ROLE) { _pause(); }
    function unpause() external onlyRole(OWNER_ROLE) { _unpause(); }

    // ═══════════════════════════════════════════════════════════
    //  INTERNALS
    // ═══════════════════════════════════════════════════════════

    /// @dev Read the wstETH/stETH rate from Chainlink. Returns 0 on failure.
    function _currentRate() internal view returns (uint256) {
        try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return answer > 0 ? uint256(answer) : 0;
        } catch {
            return 0;
        }
    }

    /// @dev Minimum wstETH to back principal (ceiling-rounded).
    ///      Returns full deposit when rate is unavailable (blocks all claims).
    function _principalWstETHFloor() internal view returns (uint256) {
        if (wstETHDeposited == 0) return 0;
        uint256 rate = _currentRate();
        if (rate == 0) return wstETHDeposited;
        return Math.mulDiv(wstETHDeposited, initialRate, rate, Math.Rounding.Ceil);
    }

    /// @dev Snapshot unclaimed yield into bonus, reset counters, update rate anchor.
    ///      Called before subsequent deposits and partial withdrawals.
    function _reanchor() internal {
        uint256 rate = _currentRate();
        if (rate == 0 || wstETHDeposited == 0) return;

        uint256 rawYield = rate > initialRate
            ? Math.mulDiv(wstETHDeposited, rate - initialRate, rate)
            : 0;

        uint256 total = rawYield + pendingYieldBonus;
        pendingYieldBonus = total > totalYieldClaimed ? total - totalYieldClaimed : 0;
        totalYieldClaimed = 0;
        initialRate = rate;
    }
}
