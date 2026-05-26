// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Tests covering the v2 gasless `createEscrowFor*` entrypoints.
/// Legacy entrypoints are exercised in TabEscrowRouter.t.sol; here we
/// focus on EIP-712 signature verification, replay protection (via the
/// existing per-escrow `id` collision check), and the executor-only
/// modifier.
contract TabEscrowRouterV2Test is Test {
    TabEscrowRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    // Use a fixed private key so we can sign EIP-712 messages.
    uint256 internal constant ALICE_PK = 0xA11CE;
    address internal alice;
    uint256 internal constant BAD_PK = 0xBADBAD;

    uint256 internal constant FEE_BPS = 100;

    bytes32 internal CREATE_HANDLE_TYPEHASH;
    bytes32 internal CREATE_CODE_TYPEHASH;

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        usdc = new MockUSDC(18);
        router = new TabEscrowRouter(address(usdc), treasury, FEE_BPS, executor);

        usdc.mint(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        CREATE_HANDLE_TYPEHASH = router.CREATE_ESCROW_HANDLE_TYPEHASH();
        CREATE_CODE_TYPEHASH = router.CREATE_ESCROW_CODE_TYPEHASH();
    }

    /* ------------------------------- handle ------------------------------- */

    function test_CreateEscrowForHandle_HappyPath() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 7 days;
        uint256 senderNonce = 42;
        bytes memory sig = _signHandle(ALICE_PK, alice, "bob", amount, deadline, senderNonce);

        vm.prank(executor);
        bytes32 id = router.createEscrowForHandle(alice, "bob", amount, deadline, senderNonce, sig);

        assertTrue(router.escrowExists(id));
        assertEq(usdc.balanceOf(address(router)), amount);
        assertEq(usdc.balanceOf(alice), 1_000 ether - amount);

        (address sender, , , , , , ) = router.escrows(id);
        assertEq(sender, alice, "escrow.sender must be the signer, not the executor");
    }

    function test_CreateEscrowForHandle_MatchesLegacyId() public {
        // The v2 entrypoint must derive the same `id` the legacy
        // entrypoint would, so existing claim/refund paths keep working
        // against escrows opened via the gasless flow.
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 days;
        uint256 senderNonce = 7;

        bytes memory sig = _signHandle(ALICE_PK, alice, "bob", amount, deadline, senderNonce);
        vm.prank(executor);
        bytes32 gaslessId = router.createEscrowForHandle(alice, "bob", amount, deadline, senderNonce, sig);

        bytes32 expectedId = router.computeHandleId(alice, "bob", senderNonce);
        assertEq(gaslessId, expectedId, "v2 id must match computeHandleId");
    }

    function test_Revert_CreateEscrowForHandle_BadSig() public {
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        // Signed by the wrong key.
        bytes memory sig = _signHandle(BAD_PK, alice, "bob", amount, deadline, 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.InvalidSignature.selector);
        router.createEscrowForHandle(alice, "bob", amount, deadline, 1, sig);
    }

    function test_Revert_CreateEscrowForHandle_TamperedAmount() public {
        // Sign for 1 ETH, submit for 100 ETH → signature recovers to
        // the wrong signer → revert.
        bytes memory sig = _signHandle(ALICE_PK, alice, "bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.InvalidSignature.selector);
        router.createEscrowForHandle(alice, "bob", 100 ether, block.timestamp + 1 days, 1, sig);
    }

    function test_Revert_CreateEscrowForHandle_NonExecutor() public {
        bytes memory sig = _signHandle(ALICE_PK, alice, "bob", 1 ether, block.timestamp + 1 days, 1);
        vm.prank(stranger);
        vm.expectRevert(TabEscrowRouter.NotExecutor.selector);
        router.createEscrowForHandle(alice, "bob", 1 ether, block.timestamp + 1 days, 1, sig);
    }

    function test_Revert_CreateEscrowForHandle_ReplayBlocked() public {
        // Same signature submitted twice → second call reverts on the
        // existing-id collision check.
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signHandle(ALICE_PK, alice, "bob", 1 ether, deadline, 1);

        vm.prank(executor);
        router.createEscrowForHandle(alice, "bob", 1 ether, deadline, 1, sig);

        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.EscrowAlreadyExists.selector);
        router.createEscrowForHandle(alice, "bob", 1 ether, deadline, 1, sig);
    }

    /* ------------------------------- code ------------------------------- */

    function test_CreateEscrowForCode_HappyPath() public {
        uint256 amount = 50 ether;
        uint256 deadline = block.timestamp + 1 days;
        uint256 senderNonce = 9;
        bytes32 codeHash = keccak256("secret");

        bytes memory sig = _signCode(ALICE_PK, alice, codeHash, amount, deadline, senderNonce);
        vm.prank(executor);
        bytes32 id = router.createEscrowForCode(alice, codeHash, amount, deadline, senderNonce, sig);

        assertTrue(router.escrowExists(id));
        (address sender, bytes32 commitment, , , , TabEscrowRouter.ClaimType claimType, ) = router.escrows(id);
        assertEq(sender, alice);
        assertEq(commitment, codeHash);
        assertEq(uint256(claimType), uint256(TabEscrowRouter.ClaimType.Code));
    }

    function test_Revert_CreateEscrowForCode_BadSig() public {
        bytes32 codeHash = keccak256("secret");
        bytes memory sig = _signCode(BAD_PK, alice, codeHash, 1 ether, block.timestamp + 1 days, 1);
        vm.prank(executor);
        vm.expectRevert(TabEscrowRouter.InvalidSignature.selector);
        router.createEscrowForCode(alice, codeHash, 1 ether, block.timestamp + 1 days, 1, sig);
    }

    /* ----------------------- legacy paths unchanged ---------------------- */

    function test_Legacy_CreateEscrow_StillWorks() public {
        // The v2 refactor preserved the public createEscrow / createEscrowByCode
        // entrypoints — they should still operate on msg.sender.
        vm.prank(alice);
        bytes32 id = router.createEscrow("bob", 1 ether, block.timestamp + 1 days, 1);
        (address sender, , , , , , ) = router.escrows(id);
        assertEq(sender, alice);
    }

    /* ------------------------------- helpers ------------------------------ */

    function _signHandle(
        uint256 pk,
        address sender,
        string memory handleSlug,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_HANDLE_TYPEHASH,
                sender,
                keccak256(bytes(handleSlug)),
                amount,
                deadline,
                senderNonce
            )
        );
        bytes32 digest = _digest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCode(
        uint256 pk,
        address sender,
        bytes32 codeHash,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(CREATE_CODE_TYPEHASH, sender, codeHash, amount, deadline, senderNonce)
        );
        bytes32 digest = _digest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash));
    }
}
