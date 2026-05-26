// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TabEscrowRouterTest is Test {
    TabEscrowRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    address internal alice = makeAddr("alice"); // sender
    address internal bob   = makeAddr("bob");   // recipient

    uint256 internal constant FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC(18);
        router = new TabEscrowRouter(address(usdc), treasury, FEE_BPS, executor);

        usdc.mint(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    /* ----------------------------- create ----------------------------- */

    function test_CreateEscrow_LocksFunds() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", amount, deadline, 1);

        assertTrue(router.escrowExists(id));
        assertEq(usdc.balanceOf(address(router)), amount);
        assertEq(usdc.balanceOf(alice), 1_000 ether - amount);

        (
            address sender,
            bytes32 commitment,
            uint256 storedAmount,
            uint256 storedDeadline,
            uint16 feeBps,
            TabEscrowRouter.ClaimType claimType,
            TabEscrowRouter.Status status
        ) = router.escrows(id);
        assertEq(sender, alice);
        assertEq(commitment, keccak256(bytes("bob")));
        assertEq(storedAmount, amount);
        assertEq(storedDeadline, deadline);
        assertEq(uint256(feeBps), 100);
        assertEq(uint256(claimType), uint256(TabEscrowRouter.ClaimType.Handle));
        assertEq(uint256(status), uint256(TabEscrowRouter.Status.Pending));
    }

    function test_CreateEscrow_ParallelTabsToSameHandle() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.startPrank(alice);
        bytes32 id1 = router.createEscrow("bob", 10 ether, deadline, 1);
        bytes32 id2 = router.createEscrow("bob", 20 ether, deadline, 2);
        vm.stopPrank();
        assertTrue(id1 != id2);
        assertTrue(router.escrowExists(id1));
        assertTrue(router.escrowExists(id2));
    }

    function test_Revert_CreateEscrow_DuplicateNonce() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        router.createEscrow("bob", 10 ether, deadline, 7);
        vm.prank(alice);
        vm.expectRevert(TabEscrowRouter.EscrowAlreadyExists.selector);
        router.createEscrow("bob", 5 ether, deadline, 7);
    }

    function test_Revert_CreateEscrow_EmptyHandle() public {
        vm.prank(alice);
        vm.expectRevert(TabEscrowRouter.EmptyHandle.selector);
        router.createEscrow("", 1 ether, block.timestamp + 1 days, 1);
    }

    function test_Revert_CreateEscrow_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TabEscrowRouter.InvalidAmount.selector);
        router.createEscrow("bob", 0, block.timestamp + 1 days, 1);
    }

    function test_Revert_CreateEscrow_DeadlineTooSoon() public {
        vm.prank(alice);
        vm.expectRevert(TabEscrowRouter.InvalidDeadline.selector);
        router.createEscrow("bob", 1 ether, block.timestamp + 30 minutes, 1);
    }

    function test_Revert_CreateEscrow_DeadlineTooFar() public {
        vm.prank(alice);
        vm.expectRevert(TabEscrowRouter.InvalidDeadline.selector);
        router.createEscrow("bob", 1 ether, block.timestamp + 100 days, 1);
    }

    /* ------------------------------ claim ----------------------------- */

    function test_Claim_PaysRecipientMinusFee() public {
        uint256 amount = 100 ether;
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", amount, block.timestamp + 1 days, 1);

        uint256 expectedFee = (amount * FEE_BPS) / 10_000;
        uint256 expectedNet = amount - expectedFee;

        vm.prank(executor);
        router.claim(id, "bob", bob);

        assertEq(usdc.balanceOf(bob), expectedNet);
        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(address(router)), 0);

        (, , , , , , TabEscrowRouter.Status status) = router.escrows(id);
        assertEq(uint256(status), uint256(TabEscrowRouter.Status.Claimed));
    }

    function test_Revert_Claim_NotExecutor() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.NotExecutor.selector);
        router.claim(id, "bob", bob);
    }

    function test_Revert_Claim_WrongHandle() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.HandleMismatch.selector);
        router.claim(id, "alice", bob);
    }

    function test_Revert_Claim_ZeroRecipient() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.ZeroAddress.selector);
        router.claim(id, "bob", address(0));
    }

    function test_Revert_Claim_DoubleClaim() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.startPrank(executor);
        router.claim(id, "bob", bob);
        vm.expectRevert(TabEscrowRouter.EscrowNotPending.selector);
        router.claim(id, "bob", bob);
        vm.stopPrank();
    }

    function test_Revert_Claim_AfterDeadline() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, deadline, 1);
        vm.warp(deadline + 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.EscrowExpired.selector);
        router.claim(id, "bob", bob);
    }

    /* ------------------------------ refund ---------------------------- */

    function test_Refund_AfterDeadline() public {
        uint256 amount = 50 ether;
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", amount, deadline, 1);

        vm.warp(deadline + 1);

        // Anyone can call refund — pull pattern.
        vm.prank(stranger);
        router.refund(id);

        assertEq(usdc.balanceOf(alice), 1_000 ether);
        assertEq(usdc.balanceOf(address(router)), 0);

        (, , , , , , TabEscrowRouter.Status status) = router.escrows(id);
        assertEq(uint256(status), uint256(TabEscrowRouter.Status.Refunded));
    }

    function test_Revert_Refund_BeforeDeadline() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.expectRevert(TabEscrowRouter.EscrowNotExpired.selector);
        router.refund(id);
    }

    function test_Revert_Refund_AlreadyClaimed() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(executor);
        router.claim(id, "bob", bob);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(TabEscrowRouter.EscrowNotPending.selector);
        router.refund(id);
    }

    /* ----------------------------- admin ----------------------------- */

    function test_SetPlatformFee_RespectsCap() public {
        router.setPlatformFee(500);
        assertEq(router.platformFeeBps(), 500);
        vm.expectRevert(TabEscrowRouter.FeeTooHigh.selector);
        router.setPlatformFee(501);
    }

    function test_AddRemoveExecutor() public {
        address newExec = makeAddr("newExec");
        router.addExecutor(newExec);
        assertTrue(router.executors(newExec));
        router.removeExecutor(newExec);
        assertFalse(router.executors(newExec));
    }

    function test_Revert_ConstructorFeeTooHigh() public {
        vm.expectRevert(TabEscrowRouter.FeeTooHigh.selector);
        new TabEscrowRouter(address(usdc), treasury, 501, executor);
    }

    /* ----------------------------- fuzz ----------------------------- */

    function testFuzz_FeeMath(uint128 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        router.setPlatformFee(feeBps);
        (uint256 fee, uint256 net) = router.calculateFee(amount);
        assertEq(fee + net, amount);
    }

    function testFuzz_CreateAndClaim(uint128 amount) public {
        amount = uint128(bound(amount, 1, 500 ether));
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", amount, block.timestamp + 1 days, 42);
        vm.prank(executor);
        router.claim(id, "bob", bob);
        uint256 expectedFee = (uint256(amount) * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(bob), uint256(amount) - expectedFee);
    }

    /* --------------------- claim-by-code (new) ----------------------- */

    function _codeAndHash(bytes32 seed) internal pure returns (bytes memory secret, bytes32 codeHash) {
        secret = abi.encodePacked(seed);
        codeHash = keccak256(secret);
    }

    function test_CreateEscrowByCode_LocksFunds() public {
        (, bytes32 codeHash) = _codeAndHash(keccak256("magic"));
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, amount, deadline, 1);

        assertEq(usdc.balanceOf(address(router)), amount);

        (
            address sender,
            bytes32 commitment,
            uint256 storedAmount,
            uint256 storedDeadline,
            uint16 feeBps,
            TabEscrowRouter.ClaimType claimType,
            TabEscrowRouter.Status status
        ) = router.escrows(id);
        assertEq(sender, alice);
        assertEq(commitment, codeHash);
        assertEq(storedAmount, amount);
        assertEq(storedDeadline, deadline);
        assertEq(uint256(feeBps), FEE_BPS);
        assertEq(uint256(claimType), uint256(TabEscrowRouter.ClaimType.Code));
        assertEq(uint256(status), uint256(TabEscrowRouter.Status.Pending));
    }

    function test_ClaimByCode_AnyWalletWithSecretClaims() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("magic-1"));
        uint256 amount = 50 ether;

        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, amount, block.timestamp + 1 days, 1);

        // A complete stranger with the secret can claim — no executor, no handle.
        vm.prank(stranger);
        router.claimByCode(id, secret);

        uint256 expectedFee = (amount * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(stranger), amount - expectedFee);
        assertEq(usdc.balanceOf(treasury), expectedFee);
        (, , , , , , TabEscrowRouter.Status status) = router.escrows(id);
        assertEq(uint256(status), uint256(TabEscrowRouter.Status.Claimed));
    }

    function test_Revert_ClaimByCode_WrongSecret() public {
        (, bytes32 codeHash) = _codeAndHash(keccak256("magic-2"));
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 1 ether, block.timestamp + 1 days, 1);

        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.CodeMismatch.selector);
        router.claimByCode(id, abi.encodePacked(keccak256("wrong")));
    }

    function test_Revert_ClaimByCode_DoubleClaim() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("magic-3"));
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 1 ether, block.timestamp + 1 days, 1);

        vm.prank(stranger);
        router.claimByCode(id, secret);

        vm.prank(bob);
        vm.expectRevert(TabEscrowRouter.EscrowNotPending.selector);
        router.claimByCode(id, secret);
    }

    function test_Revert_ClaimByCode_AfterDeadline() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("magic-4"));
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 1 ether, deadline, 1);

        vm.warp(deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.EscrowExpired.selector);
        router.claimByCode(id, secret);
    }

    function test_Revert_ClaimByCode_WrongType() public {
        // Handle escrow can't be claimed via claimByCode and vice versa.
        vm.prank(alice);
        bytes32 handleId = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);

        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.WrongClaimType.selector);
        router.claimByCode(handleId, abi.encodePacked(keccak256("any")));
    }

    function test_ClaimByCodeFor_ExecutorSponsoredClaim() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("sponsored"));
        uint256 amount = 100 ether;

        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, amount, block.timestamp + 1 days, 1);

        // Executor pays gas; funds go to bob (the actual recipient).
        vm.prank(executor);
        router.claimByCodeFor(id, bob, secret);

        uint256 expectedFee = (amount * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(bob), amount - expectedFee);
        assertEq(usdc.balanceOf(executor), 0); // executor gets nothing
    }

    function test_Revert_ClaimByCodeFor_NotExecutor() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("nope"));
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 1 ether, block.timestamp + 1 days, 1);

        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.NotExecutor.selector);
        router.claimByCodeFor(id, bob, secret);
    }

    function test_Revert_ClaimByCodeFor_ZeroRecipient() public {
        (bytes memory secret, bytes32 codeHash) = _codeAndHash(keccak256("nope2"));
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 1 ether, block.timestamp + 1 days, 1);

        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.ZeroAddress.selector);
        router.claimByCodeFor(id, address(0), secret);
    }

    function test_RefundCodeEscrow_AfterDeadline() public {
        (, bytes32 codeHash) = _codeAndHash(keccak256("refund-me"));
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        bytes32 id = router.createEscrowByCode(codeHash, 50 ether, deadline, 1);

        vm.warp(deadline + 1);
        router.refund(id);
        assertEq(usdc.balanceOf(alice), 1_000 ether);
    }

    function test_CodeAndHandleIdsCannotCollide() public {
        // Same sender, same nonce, same commitment-via-keccak — but different
        // ClaimType means different ids. Otherwise a handle "bob" and a code
        // whose hash equals keccak256("bob") would collide.
        bytes32 handleHash = keccak256(bytes("bob"));
        vm.prank(alice);
        bytes32 handleId = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 7);
        vm.prank(alice);
        // codeHash == handleHash — these would collide without ClaimType in ID
        bytes32 codeId = router.createEscrowByCode(handleHash, 2 ether, block.timestamp + 1 days, 7);
        assertTrue(handleId != codeId);
    }

    /* ---------------------- fee snapshot --------------------------- */

    function test_FeeSnapshot_ChangeAfterCreationDoesntAffectExisting() public {
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 100 ether, block.timestamp + 1 days, 1);

        // Owner cranks fee to 5% AFTER escrow exists — escrow keeps its 1%.
        router.setPlatformFee(500);

        vm.prank(executor);
        router.claim(id, "bob", bob);

        // Should still be 1% (1 ether on 100 ether), not 5%.
        assertEq(usdc.balanceOf(bob), 99 ether);
        assertEq(usdc.balanceOf(treasury), 1 ether);
    }

    /* ----------------------- pause ---------------------------- */

    function test_Pause_BlocksCreate() public {
        router.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
    }

    function test_Pause_DoesNotBlockClaim() public {
        // Critical: pausing must never trap user funds. Existing escrows
        // remain claimable and refundable during a pause.
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        router.pause();
        vm.prank(executor);
        router.claim(id, "bob", bob); // should NOT revert
        assertEq(usdc.balanceOf(bob), 0.99 ether);
    }

    function test_Pause_DoesNotBlockRefund() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, deadline, 1);
        vm.warp(deadline + 1);
        router.pause();
        router.refund(id); // should NOT revert
        assertEq(usdc.balanceOf(alice), 1_000 ether);
    }
}
