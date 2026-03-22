// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentTreasury, AggregatorV3Interface} from "../src/AgentTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AgentTreasury Test Suite — Base Mainnet Fork
/// @notice 40 tests covering deposit, withdraw, yield, permissions, edge cases, and fuzz.
contract AgentTreasuryTest is Test {
    // ─── Base mainnet constants ──────────────────────────────
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant CHAINLINK_FEED = 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061;

    AgentTreasury treasury;
    IERC20 wstETH = IERC20(WSTETH);

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address recipient = makeAddr("recipient");
    address recipient2 = makeAddr("recipient2");
    address stranger = makeAddr("stranger");

    uint256 constant DEPOSIT = 10 ether;

    uint256 initialRate;

    function setUp() public {
        vm.createSelectFork("base");

        treasury = new AgentTreasury(WSTETH, CHAINLINK_FEED, owner, agent);

        // Cache the live oracle rate
        (, int256 answer,,,) = AggregatorV3Interface(CHAINLINK_FEED).latestRoundData();
        initialRate = uint256(answer);

        // Fund owner with wstETH
        deal(WSTETH, owner, 1000 ether);

        // Blanket approval
        vm.prank(owner);
        wstETH.approve(address(treasury), type(uint256).max);

        // Whitelist default recipient
        vm.prank(owner);
        treasury.addRecipient(recipient);
    }

    // ─── Helpers ─────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        vm.prank(owner);
        treasury.deposit(amount);
    }

    function _mockRate(uint256 rate) internal {
        vm.mockCall(
            CHAINLINK_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(rate), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _expectedYield(uint256 w, uint256 r0, uint256 rt) internal pure returns (uint256) {
        if (rt <= r0 || w == 0) return 0;
        return Math.mulDiv(w, rt - r0, rt);
    }

    // ═══════════════════════════════════════════════════════════
    //  1. CONSTRUCTOR & INITIAL STATE  (6 tests)
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsRolesCorrectly() public view {
        assertTrue(treasury.hasRole(treasury.OWNER_ROLE(), owner));
        assertTrue(treasury.hasRole(treasury.AGENT_ROLE(), agent));
        assertFalse(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(treasury.wstETH()), WSTETH);
        assertEq(address(treasury.priceFeed()), CHAINLINK_FEED);
    }

    function test_constructor_revertsZeroWstETH() public {
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(address(0), CHAINLINK_FEED, owner, agent);
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(WSTETH, CHAINLINK_FEED, address(0), agent);
    }

    function test_constructor_revertsZeroAgent() public {
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(WSTETH, CHAINLINK_FEED, owner, address(0));
    }

    function test_initialState_allZero() public view {
        assertEq(treasury.wstETHDeposited(), 0);
        assertEq(treasury.initialRate(), 0);
        assertEq(treasury.pendingYieldBonus(), 0);
        assertEq(treasury.totalYieldClaimed(), 0);
        assertEq(treasury.getAvailableYield(), 0);
        assertEq(uint256(treasury.maxPerTransaction()), 0);
        assertFalse(treasury.paused());
    }

    // ═══════════════════════════════════════════════════════════
    //  2. DEPOSIT  (5 tests)
    // ═══════════════════════════════════════════════════════════

    function test_deposit_transfersAndRecords() public {
        uint256 balBefore = wstETH.balanceOf(address(treasury));
        _deposit(DEPOSIT);

        assertEq(treasury.wstETHDeposited(), DEPOSIT);
        assertEq(treasury.initialRate(), initialRate);
        assertEq(wstETH.balanceOf(address(treasury)), balBefore + DEPOSIT);
    }

    function test_deposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AgentTreasury.Deposited(owner, DEPOSIT, initialRate);
        _deposit(DEPOSIT);
    }

    function test_deposit_revertsForNonOwner() public {
        deal(WSTETH, stranger, DEPOSIT);
        vm.startPrank(stranger);
        wstETH.approve(address(treasury), DEPOSIT);
        vm.expectRevert();
        treasury.deposit(DEPOSIT);
        vm.stopPrank();
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(AgentTreasury.ZeroAmount.selector);
        treasury.deposit(0);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(owner);
        treasury.pause();

        vm.prank(owner);
        vm.expectRevert();
        treasury.deposit(DEPOSIT);
    }

    // ═══════════════════════════════════════════════════════════
    //  3. WITHDRAW PRINCIPAL  (6 tests)
    // ═══════════════════════════════════════════════════════════

    function test_withdraw_fullResetsState() public {
        _deposit(DEPOSIT);

        uint256 ownerBefore = wstETH.balanceOf(owner);
        vm.prank(owner);
        treasury.withdrawPrincipal(DEPOSIT, owner);

        assertEq(treasury.wstETHDeposited(), 0);
        assertEq(treasury.initialRate(), 0);
        assertEq(treasury.pendingYieldBonus(), 0);
        assertEq(treasury.totalYieldClaimed(), 0);
        assertEq(wstETH.balanceOf(owner), ownerBefore + DEPOSIT);
    }

    function test_withdraw_partialReanchors() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 103 / 100;
        _mockRate(newRate);

        uint256 half = DEPOSIT / 2;
        vm.prank(owner);
        treasury.withdrawPrincipal(half, owner);

        assertEq(treasury.wstETHDeposited(), DEPOSIT - half);
        assertEq(treasury.initialRate(), newRate);
    }

    function test_withdraw_emitsEvent() public {
        _deposit(DEPOSIT);
        vm.expectEmit(true, true, false, true);
        emit AgentTreasury.PrincipalWithdrawn(owner, DEPOSIT, recipient);
        vm.prank(owner);
        treasury.withdrawPrincipal(DEPOSIT, recipient);
    }

    function test_withdraw_revertsForNonOwner() public {
        _deposit(DEPOSIT);
        vm.prank(agent);
        vm.expectRevert();
        treasury.withdrawPrincipal(DEPOSIT, agent);
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        vm.expectRevert(AgentTreasury.InsufficientBalance.selector);
        treasury.withdrawPrincipal(DEPOSIT + 1, owner);
    }

    function test_withdraw_worksWhenPaused() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        treasury.pause();

        vm.prank(owner);
        treasury.withdrawPrincipal(DEPOSIT, owner);
        assertEq(treasury.wstETHDeposited(), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  4. YIELD CALCULATION  (5 tests)
    // ═══════════════════════════════════════════════════════════

    function test_yield_zeroWhenRateUnchanged() public {
        _deposit(DEPOSIT);
        assertEq(treasury.getAvailableYield(), 0);
    }

    function test_yield_accruedOnRateIncrease() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 110 / 100; // +10%
        _mockRate(newRate);

        uint256 expected = _expectedYield(DEPOSIT, initialRate, newRate);
        assertEq(treasury.getAvailableYield(), expected);
        assertGt(expected, 0);
    }

    function test_yield_zeroOnRateDecrease() public {
        _deposit(DEPOSIT);
        uint256 lower = initialRate * 95 / 100; // -5% slashing
        _mockRate(lower);

        assertEq(treasury.getAvailableYield(), 0);
    }

    function test_yield_inStETHConvertsCorrectly() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 105 / 100;
        _mockRate(newRate);

        uint256 yieldWst = treasury.getAvailableYield();
        uint256 yieldStETH = treasury.getAvailableYieldInStETH();
        assertApproxEqAbs(yieldStETH, Math.mulDiv(yieldWst, newRate, 1e18), 1);
    }

    function test_yield_principalValuePreservedAfterRateChange() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 120 / 100;
        _mockRate(newRate);

        uint256 principalStETH = treasury.getPrincipalValue();
        assertEq(principalStETH, Math.mulDiv(DEPOSIT, initialRate, 1e18));
    }

    // ═══════════════════════════════════════════════════════════
    //  5. CLAIM YIELD  (8 tests)
    // ═══════════════════════════════════════════════════════════

    function test_claim_basic() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 110 / 100;
        _mockRate(newRate);

        uint256 available = treasury.getAvailableYield();
        uint256 recipBefore = wstETH.balanceOf(recipient);

        vm.prank(agent);
        treasury.claimYield(available, recipient);

        assertEq(wstETH.balanceOf(recipient), recipBefore + available);
        assertEq(treasury.totalYieldClaimed(), available);
        assertEq(treasury.getAvailableYield(), 0);
    }

    function test_claim_emitsEvent() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 105 / 100;
        _mockRate(newRate);
        uint256 available = treasury.getAvailableYield();

        vm.expectEmit(true, true, false, true);
        emit AgentTreasury.YieldClaimed(agent, available, recipient);

        vm.prank(agent);
        treasury.claimYield(available, recipient);
    }

    function test_claim_partialThenRemaining() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 110 / 100;
        _mockRate(newRate);

        uint256 available = treasury.getAvailableYield();
        uint256 half = available / 2;

        vm.startPrank(agent);
        treasury.claimYield(half, recipient);
        assertApproxEqAbs(treasury.getAvailableYield(), available - half, 1);

        uint256 remaining = treasury.getAvailableYield();
        treasury.claimYield(remaining, recipient);
        assertEq(treasury.getAvailableYield(), 0);
        vm.stopPrank();
    }

    function test_claim_revertsForNonAgent() public {
        _deposit(DEPOSIT);
        _mockRate(initialRate * 105 / 100);
        vm.prank(stranger);
        vm.expectRevert();
        treasury.claimYield(1, recipient);
    }

    function test_claim_revertsExceedsAvailable() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 105 / 100;
        _mockRate(newRate);
        uint256 available = treasury.getAvailableYield();

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.ExceedsAvailableYield.selector, available + 1, available)
        );
        treasury.claimYield(available + 1, recipient);
    }

    function test_claim_revertsNonWhitelisted() public {
        _deposit(DEPOSIT);
        _mockRate(initialRate * 105 / 100);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentTreasury.RecipientNotWhitelisted.selector, stranger));
        treasury.claimYield(1, stranger);
    }

    function test_claim_revertsWhenPaused() public {
        _deposit(DEPOSIT);
        _mockRate(initialRate * 105 / 100);

        vm.prank(owner);
        treasury.pause();

        vm.prank(agent);
        vm.expectRevert();
        treasury.claimYield(1, recipient);
    }

    function test_claim_respectsMaxPerTransaction() public {
        _deposit(DEPOSIT);
        _mockRate(initialRate * 110 / 100);

        uint128 cap = 0.01 ether;
        vm.prank(owner);
        treasury.setMaxPerTransaction(cap);

        // Over cap reverts
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.ExceedsPerTransactionCap.selector, uint256(cap) + 1, uint256(cap))
        );
        treasury.claimYield(uint256(cap) + 1, recipient);

        // Within cap succeeds
        vm.prank(agent);
        treasury.claimYield(uint256(cap), recipient);
        assertEq(wstETH.balanceOf(recipient), uint256(cap));
    }

    // ═══════════════════════════════════════════════════════════
    //  6. TOP UP YIELD  (4 tests)
    // ═══════════════════════════════════════════════════════════

    function test_topUp_addsToBonus() public {
        vm.prank(owner);
        treasury.topUpYield(1 ether);

        assertEq(treasury.pendingYieldBonus(), 1 ether);
        assertEq(treasury.getAvailableYield(), 1 ether);
    }

    function test_topUp_immediatelyClaimable() public {
        vm.prank(owner);
        treasury.topUpYield(1 ether);

        vm.prank(agent);
        treasury.claimYield(1 ether, recipient);
        assertEq(wstETH.balanceOf(recipient), 1 ether);
    }

    function test_topUp_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AgentTreasury.YieldToppedUp(owner, 1 ether);

        vm.prank(owner);
        treasury.topUpYield(1 ether);
    }

    function test_topUp_revertsForNonOwner() public {
        deal(WSTETH, stranger, 1 ether);
        vm.startPrank(stranger);
        wstETH.approve(address(treasury), 1 ether);
        vm.expectRevert();
        treasury.topUpYield(1 ether);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  7. ADMIN & PERMISSIONS  (5 tests)
    // ═══════════════════════════════════════════════════════════

    function test_admin_addAndRemoveRecipient() public {
        assertFalse(treasury.whitelistedRecipients(recipient2));

        vm.prank(owner);
        treasury.addRecipient(recipient2);
        assertTrue(treasury.whitelistedRecipients(recipient2));

        vm.prank(owner);
        treasury.removeRecipient(recipient2);
        assertFalse(treasury.whitelistedRecipients(recipient2));
    }

    function test_admin_addRecipientRevertsZero() public {
        vm.prank(owner);
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        treasury.addRecipient(address(0));
    }

    function test_admin_setMaxPerTransaction() public {
        vm.expectEmit(false, false, false, true);
        emit AgentTreasury.MaxPerTransactionUpdated(0, 5 ether);

        vm.prank(owner);
        treasury.setMaxPerTransaction(5 ether);
        assertEq(treasury.maxPerTransaction(), 5 ether);
    }

    function test_admin_ownerCanRevokeAndGrantAgent() public {
        vm.startPrank(owner);
        treasury.revokeRole(treasury.AGENT_ROLE(), agent);
        assertFalse(treasury.hasRole(treasury.AGENT_ROLE(), agent));

        address newAgent = makeAddr("newAgent");
        treasury.grantRole(treasury.AGENT_ROLE(), newAgent);
        assertTrue(treasury.hasRole(treasury.AGENT_ROLE(), newAgent));
        vm.stopPrank();
    }

    function test_admin_pauseAndUnpause() public {
        vm.prank(owner);
        treasury.pause();
        assertTrue(treasury.paused());

        vm.prank(owner);
        treasury.unpause();
        assertFalse(treasury.paused());
    }

    // ═══════════════════════════════════════════════════════════
    //  8. EDGE CASES & INTEGRATION  (7 tests)
    // ═══════════════════════════════════════════════════════════

    function test_edge_fullWithdrawThenRedeposit() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        treasury.withdrawPrincipal(DEPOSIT, owner);

        assertEq(treasury.wstETHDeposited(), 0);
        assertEq(treasury.initialRate(), 0);

        _deposit(DEPOSIT);
        assertEq(treasury.wstETHDeposited(), DEPOSIT);
        assertGt(treasury.initialRate(), 0);
    }

    function test_edge_rateZeroBonusStillClaimable() public {
        _deposit(DEPOSIT);

        // Add bonus yield
        vm.prank(owner);
        treasury.topUpYield(1 ether);

        // Oracle fails → rate = 0
        _mockRate(0);

        // Bonus yield remains visible
        uint256 available = treasury.getAvailableYield();
        assertEq(available, 1 ether);

        // Claim succeeds because balance (11 ether) >= floor (10 ether when rate=0)
        vm.prank(agent);
        treasury.claimYield(1 ether, recipient);
        assertEq(wstETH.balanceOf(recipient), 1 ether);
    }

    function test_edge_multipleDepositsPreserveYield() public {
        _deposit(DEPOSIT);

        // Rate rises 5%
        uint256 rate2 = initialRate * 105 / 100;
        _mockRate(rate2);
        uint256 yieldBefore = treasury.getAvailableYield();
        assertGt(yieldBefore, 0);

        // Second deposit triggers reanchor → snapshots yield
        _deposit(DEPOSIT);

        // Rate rises another 3%
        uint256 rate3 = rate2 * 103 / 100;
        _mockRate(rate3);

        uint256 yieldAfter = treasury.getAvailableYield();
        uint256 newYield = _expectedYield(DEPOSIT * 2, rate2, rate3);
        assertApproxEqAbs(yieldAfter, yieldBefore + newYield, 2);
    }

    function test_edge_principalFloorHoldsAfterMaxClaim() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 150 / 100; // +50%
        _mockRate(newRate);

        uint256 available = treasury.getAvailableYield();
        assertGt(available, 0);
        assertLt(available, DEPOSIT);

        vm.prank(agent);
        treasury.claimYield(available, recipient);

        uint256 bal = wstETH.balanceOf(address(treasury));
        uint256 floor = treasury.principalWstETHFloor();
        assertGe(bal, floor);
    }

    function test_edge_topUpPlusRateYieldCombined() public {
        _deposit(DEPOSIT);

        uint256 topUp = 0.5 ether;
        vm.prank(owner);
        treasury.topUpYield(topUp);

        uint256 newRate = initialRate * 105 / 100;
        _mockRate(newRate);

        uint256 rateYield = _expectedYield(DEPOSIT, initialRate, newRate);
        uint256 totalAvailable = treasury.getAvailableYield();
        assertApproxEqAbs(totalAvailable, rateYield + topUp, 1);
    }

    function test_edge_getStatus_comprehensive() public {
        _deposit(DEPOSIT);
        uint256 newRate = initialRate * 108 / 100;
        _mockRate(newRate);

        AgentTreasury.TreasuryStatus memory s = treasury.getStatus();

        assertEq(s.currentRate, newRate);
        assertEq(s.availableYield, treasury.getAvailableYield());
        assertGt(s.availableYieldStETH, 0);
        assertEq(s.principalValueStETH, Math.mulDiv(DEPOSIT, initialRate, 1e18));
        assertGt(s.principalFloor, 0);
        assertEq(s.contractBalance, wstETH.balanceOf(address(treasury)));
        assertEq(uint256(s.maxPerTx), 0);
        assertFalse(s.isPaused);
    }

    function test_edge_claimAfterSlashingRecovery() public {
        _deposit(DEPOSIT);

        // Rate drops (slashing) → no yield
        uint256 slashedRate = initialRate * 98 / 100;
        _mockRate(slashedRate);
        assertEq(treasury.getAvailableYield(), 0);

        // Rate recovers past initial → yield appears
        uint256 recoveredRate = initialRate * 106 / 100;
        _mockRate(recoveredRate);

        uint256 available = treasury.getAvailableYield();
        uint256 expected = _expectedYield(DEPOSIT, initialRate, recoveredRate);
        assertEq(available, expected);
        assertGt(available, 0);

        // Agent can claim recovered yield
        vm.prank(agent);
        treasury.claimYield(available, recipient);
        assertEq(wstETH.balanceOf(recipient), available);
    }

    // ═══════════════════════════════════════════════════════════
    //  9. FUZZ TESTS  (3 tests)
    // ═══════════════════════════════════════════════════════════

    function testFuzz_depositAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, 500 ether);
        deal(WSTETH, owner, amount);
        vm.prank(owner);
        wstETH.approve(address(treasury), amount);

        _deposit(amount);
        assertEq(treasury.wstETHDeposited(), amount);
    }

    function testFuzz_yieldNeverExceedsPrincipal(uint256 bps) public {
        bps = bound(bps, 1, 10_000); // 0.01% to 100% rate increase
        _deposit(DEPOSIT);

        uint256 newRate = initialRate + (initialRate * bps / 10_000);
        _mockRate(newRate);

        assertLe(treasury.getAvailableYield(), DEPOSIT);
    }

    function testFuzz_principalFloorInvariant(uint256 bps) public {
        bps = bound(bps, 1, 10_000);
        _deposit(DEPOSIT);

        uint256 newRate = initialRate + (initialRate * bps / 10_000);
        _mockRate(newRate);

        uint256 available = treasury.getAvailableYield();
        if (available > 0) {
            vm.prank(agent);
            treasury.claimYield(available, recipient);

            uint256 bal = wstETH.balanceOf(address(treasury));
            uint256 floor = treasury.principalWstETHFloor();
            assertGe(bal, floor, "principal floor violated");
        }
    }
}
