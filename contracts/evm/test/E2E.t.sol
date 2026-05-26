// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {TabRouter} from "../src/TabRouter.sol";
import {TabBotRouter} from "../src/TabBotRouter.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title End-to-end integration test for the Tab payment platform.
/// @notice Simulates the entire user journey across all 4 contracts in
///         one script so we can prove the moving parts compose correctly:
///
///   - Direct gasless payment (Bob pays Alice via TabRouter, relayer
///     submits a signed Payment)
///   - OpenTab escrow (Alice opens a tab for an unknown handle, recipient
///     onboards + executor releases it, and a separate tab is refunded)
///   - Subscription (Alice publishes a plan, Charlie subscribes, the cron
///     equivalent charges the next period, allowance revocation halts)
///   - Bot-driven P2P (executor relays a tip from Bob's TG message to Alice)
///   - Campaign grant (Alice loads sponsor, executor dispatches to Dave)
///
/// Every step checks before/after balances and on-chain state so a
/// regression anywhere in the stack would fail loudly.
contract E2ETest is Test {
    /* ----------------------------- personae ----------------------------- */

    address internal deployer = makeAddr("deployer");
    address internal treasury = makeAddr("treasury");
    address internal executor;       // EOA for relayer
    uint256 internal executorPk;

    address internal alice;          // merchant + plan creator + campaign sponsor
    uint256 internal alicePk;
    address internal bob;            // buyer / TG sender
    uint256 internal bobPk;
    address internal charlie;        // subscriber
    uint256 internal charliePk;
    address internal dave;           // campaign recipient
    address internal newHandleRecipient = makeAddr("late-signup");

    /* ------------------------------ system ------------------------------ */

    MockUSDC internal stable;
    TabRouter internal router;
    TabBotRouter internal botRouter;
    TabEscrowRouter internal escrow;
    TabSubscriptionRouter internal subs;

    /* ---------------------------- constants ---------------------------- */

    uint256 internal constant FEE_BPS = 100; // 1%
    uint8 internal constant DECIMALS = 6;
    uint256 internal constant ONE_USDC = 10 ** DECIMALS;

    function setUp() public {
        (executor, executorPk) = makeAddrAndKey("executor");
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (charlie, charliePk) = makeAddrAndKey("charlie");
        dave = makeAddr("dave");

        vm.startPrank(deployer);
        stable = new MockUSDC(DECIMALS);
        router = new TabRouter(address(stable), treasury, FEE_BPS);
        botRouter = new TabBotRouter(address(stable), treasury, FEE_BPS, executor);
        escrow = new TabEscrowRouter(address(stable), treasury, FEE_BPS, executor);
        subs = new TabSubscriptionRouter(IERC20(address(stable)), treasury, FEE_BPS);
        vm.stopPrank();

        // Mint starting balances — enough for every step combined.
        stable.mint(alice, 10_000 * ONE_USDC);
        stable.mint(bob, 5_000 * ONE_USDC);
        stable.mint(charlie, 1_000 * ONE_USDC);

        // Pre-approve where needed.
        vm.prank(bob);
        stable.approve(address(router), type(uint256).max);
        vm.prank(bob);
        stable.approve(address(botRouter), type(uint256).max);
        vm.prank(alice);
        stable.approve(address(escrow), type(uint256).max);
        vm.prank(alice);
        stable.approve(address(botRouter), type(uint256).max);
        vm.prank(charlie);
        stable.approve(address(subs), type(uint256).max);
    }

    /// @notice The whole journey, in order, in a single test so a break
    ///         anywhere fails loudly.
    function test_FullUserJourney() public {
        _step_directPayment();
        _step_botP2P();
        _step_openTabClaim();
        _step_openTabRefund();
        _step_subscriptionLifecycle();
        _step_campaignGrant();
        _step_finalBalancesAddUp();
    }

    /* ----------------------- step 1: direct payment --------------------- */
    //
    // Bob pays Alice 100 USDC via TabRouter. Bob signs an EIP-712 Payment
    // off-chain; a permissionless relayer submits. TabRouter semantics:
    // `amount` is what the recipient receives — fee is charged ON TOP from
    // the sender. So bob debits 101, alice gets 100, treasury gets 1.

    function _step_directPayment() internal {
        uint256 amount = 100 * ONE_USDC;
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 bobBefore = stable.balanceOf(bob);
        uint256 treasuryBefore = stable.balanceOf(treasury);

        bytes memory sig = _signPayment(bobPk, bob, alice, amount, fee, nonce, deadline);

        address randomRelayer = makeAddr("random-relayer");
        vm.prank(randomRelayer);
        router.relayPayment(bob, alice, amount, fee, nonce, deadline, sig);

        assertEq(stable.balanceOf(alice), aliceBefore + amount, "alice gross");
        assertEq(stable.balanceOf(bob), bobBefore - (amount + fee), "bob debited amount+fee");
        assertEq(stable.balanceOf(treasury), treasuryBefore + fee, "treasury fee");
        assertTrue(router.isNonceUsed(bob, nonce), "nonce burned");

        // Replay must revert.
        vm.expectRevert();
        vm.prank(randomRelayer);
        router.relayPayment(bob, alice, amount, fee, nonce, deadline, sig);

        console2.log("step 1 ok: direct gasless payment");
    }

    /* --------------------- step 2: bot-driven P2P ----------------------- */
    //
    // Bob tips Alice from a Telegram message. Executor pulls 5 USDC.

    function _step_botP2P() internal {
        uint256 amount = 5 * ONE_USDC;
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 nonce = botRouter.nonces(bob);

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 bobBefore = stable.balanceOf(bob);
        uint256 treasuryBefore = stable.balanceOf(treasury);

        vm.prank(executor);
        botRouter.executeP2P(bob, alice, amount, nonce, "telegram:123:msg456");

        assertEq(stable.balanceOf(alice), aliceBefore + (amount - fee), "alice net");
        assertEq(stable.balanceOf(bob), bobBefore - amount, "bob debited gross");
        assertEq(stable.balanceOf(treasury), treasuryBefore + fee, "treasury fee");
        assertEq(botRouter.nonces(bob), nonce + 1, "nonce bumped");

        // Same tweetId can't be reused. Pre-read the nonce so the view
        // call doesn't consume our expectRevert expectation.
        uint256 nextNonce = botRouter.nonces(bob);
        vm.expectRevert();
        vm.prank(executor);
        botRouter.executeP2P(bob, alice, amount, nextNonce, "telegram:123:msg456");

        console2.log("step 2 ok: bot P2P");
    }

    /* ---------------------- step 3: OpenTab claim ----------------------- */
    //
    // Alice opens a tab for "lateuser" — a handle that doesn't exist yet.
    // Later, that user onboards as `newHandleRecipient`; executor claims.

    function _step_openTabClaim() internal {
        uint256 amount = 25 * ONE_USDC;
        uint256 deadline = block.timestamp + 30 days;
        uint256 senderNonce = 42;

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 escrowBefore = stable.balanceOf(address(escrow));

        vm.prank(alice);
        bytes32 id = escrow.createEscrow("lateuser", amount, deadline, senderNonce);

        // Funds locked in escrow, alice's balance decreased.
        assertEq(stable.balanceOf(alice), aliceBefore - amount, "alice locked");
        assertEq(stable.balanceOf(address(escrow)), escrowBefore + amount, "escrow holds");

        // Recipient onboards. Executor releases.
        uint256 recipientBefore = stable.balanceOf(newHandleRecipient);
        uint256 treasuryBefore = stable.balanceOf(treasury);
        uint256 fee = (amount * FEE_BPS) / 10_000;

        vm.prank(executor);
        escrow.claim(id, "lateuser", newHandleRecipient);

        assertEq(
            stable.balanceOf(newHandleRecipient),
            recipientBefore + (amount - fee),
            "recipient net"
        );
        assertEq(stable.balanceOf(treasury), treasuryBefore + fee, "treasury fee");
        assertEq(stable.balanceOf(address(escrow)), escrowBefore, "escrow drained");

        // Double-claim must revert.
        vm.expectRevert();
        vm.prank(executor);
        escrow.claim(id, "lateuser", newHandleRecipient);

        console2.log("step 3 ok: opentab claimed");
    }

    /* --------------------- step 4: OpenTab refund ----------------------- */

    function _step_openTabRefund() internal {
        uint256 amount = 7 * ONE_USDC;
        uint256 deadline = block.timestamp + 2 hours;
        uint256 senderNonce = 99;

        vm.prank(alice);
        bytes32 id = escrow.createEscrow("notcoming", amount, deadline, senderNonce);

        // Can't refund before deadline.
        vm.expectRevert();
        escrow.refund(id);

        // Jump past deadline. Anyone calls refund — alice gets her funds back.
        vm.warp(deadline + 1);
        uint256 aliceBefore = stable.balanceOf(alice);
        address rando = makeAddr("rando-refunder");
        vm.prank(rando);
        escrow.refund(id);
        assertEq(stable.balanceOf(alice), aliceBefore + amount, "alice refunded full");

        console2.log("step 4 ok: opentab refund after deadline");
    }

    /* ---------------- step 5: subscription full lifecycle --------------- */
    //
    // Alice publishes a $10 / 30-day plan. Charlie subscribes (first-period
    // charge fires). 30 days later anyone calls charge(); it settles again.
    // Charlie cancels. Future charges revert. We also halt via allowance
    // revocation on a sibling sub.

    function _step_subscriptionLifecycle() internal {
        uint256 amount = 10 * ONE_USDC;
        uint64 period = 30 days;

        vm.prank(alice);
        bytes32 planKey = subs.createPlan("monthly", amount, period);

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 charlieBefore = stable.balanceOf(charlie);
        uint256 treasuryBefore = stable.balanceOf(treasury);
        uint256 fee = (amount * FEE_BPS) / 10_000;

        // subscribe() charges the first period immediately.
        vm.prank(charlie);
        subs.subscribe(planKey);
        assertEq(stable.balanceOf(charlie), charlieBefore - amount, "charlie first charge");
        assertEq(stable.balanceOf(alice), aliceBefore + (amount - fee), "alice first net");
        assertEq(stable.balanceOf(treasury), treasuryBefore + fee, "treasury first fee");

        // Can't charge again before the period elapses.
        vm.expectRevert();
        subs.charge(planKey, charlie);

        // Jump a period — permissionless caller settles next charge.
        vm.warp(block.timestamp + period);
        address cron = makeAddr("cron");
        vm.prank(cron);
        subs.charge(planKey, charlie);
        assertEq(
            stable.balanceOf(charlie),
            charlieBefore - amount * 2,
            "charlie second charge"
        );

        // Charlie cancels. Next period elapses; charging reverts.
        vm.prank(charlie);
        subs.cancel(planKey);
        vm.warp(block.timestamp + period);
        vm.expectRevert();
        subs.charge(planKey, charlie);

        // Halt-via-allowance: re-subscribe, then revoke allowance, then
        // attempt to charge — must revert (the off-chain cron in tab-web
        // catches this and marks the sub `halted`).
        vm.prank(charlie);
        stable.approve(address(subs), type(uint256).max); // reset
        // Charlie's cumulative charges count carries forward — that's fine.
        // Note: cancelled subs need a new subscribe() (which charges first
        // period). To keep this test simple we test halt on a fresh sub
        // by creating a second plan and subscribing.
        vm.prank(alice);
        bytes32 halterKey = subs.createPlan("annual", 50 * ONE_USDC, uint64(365 days));
        vm.prank(charlie);
        subs.subscribe(halterKey); // first charge of $50 settles
        // Revoke allowance below the next charge amount.
        vm.prank(charlie);
        stable.approve(address(subs), 1);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert();
        subs.charge(halterKey, charlie);

        console2.log("step 5 ok: subscription lifecycle (subscribe, charge, cancel, halt)");
    }

    /* ----------------------- step 6: campaign grant --------------------- */
    //
    // Alice (sponsor) approves botRouter; executor dispatches a $20 grant
    // to Dave. Per-(campaignId, recipient) dedup means a re-run is safe.

    function _step_campaignGrant() internal {
        uint256 amount = 20 * ONE_USDC;
        uint256 fee = (amount * FEE_BPS) / 10_000;

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 daveBefore = stable.balanceOf(dave);
        uint256 treasuryBefore = stable.balanceOf(treasury);

        vm.prank(executor);
        botRouter.executeGrant(alice, dave, amount, "camp-spring-2026");

        assertEq(stable.balanceOf(alice), aliceBefore - amount, "alice loaded");
        assertEq(stable.balanceOf(dave), daveBefore + (amount - fee), "dave received");
        assertEq(stable.balanceOf(treasury), treasuryBefore + fee, "treasury fee");

        // Re-dispatch dedup.
        vm.expectRevert();
        vm.prank(executor);
        botRouter.executeGrant(alice, dave, amount, "camp-spring-2026");

        console2.log("step 6 ok: campaign grant + dedup");
    }

    /* ----------------- step 7: receipts / final totals ------------------ */
    //
    // Sanity check: the treasury's cumulative balance equals the sum of
    // every fee charged across all steps. If this assertion fails, money
    // moved somewhere it shouldn't have.

    function _step_finalBalancesAddUp() internal {
        // Fees collected:
        //   step 1: 100 USDC * 1%  = 1
        //   step 2:   5 USDC * 1%  = 0.05
        //   step 3:  25 USDC * 1%  = 0.25
        //   step 5: 4 charges × ($10 or $50) — first sub: 10 + 10 = 20 (2 fees of 0.1)
        //           second sub: 50 (1 fee of 0.5)
        //   step 6:  20 USDC * 1%  = 0.20
        //
        //   total = 1 + 0.05 + 0.25 + 0.10 + 0.10 + 0.50 + 0.20 = 2.20 USDC
        assertEq(
            stable.balanceOf(treasury),
            2_200_000,
            "treasury cumulative fees"
        );

        // No contract should be sitting on residual funds at the end —
        // every escrow was claimed or refunded, every payment settled.
        assertEq(stable.balanceOf(address(router)), 0, "router empty");
        assertEq(stable.balanceOf(address(botRouter)), 0, "bot router empty");
        assertEq(stable.balanceOf(address(escrow)), 0, "escrow empty");
        assertEq(stable.balanceOf(address(subs)), 0, "subs empty");

        console2.log("step 7 ok: receipts add up, no funds stuck");
    }

    /* --------------------------- helpers -------------------------------- */

    function _signPayment(
        uint256 signerPk,
        address from,
        address to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                router.PAYMENT_TYPEHASH(),
                from,
                to,
                amount,
                fee,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", router.domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
