// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TabRouter} from "../src/TabRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TabRouterTest is Test {
    TabRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal recipient = makeAddr("recipient");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    Vm.Wallet internal alice;

    function setUp() public {
        alice = vm.createWallet("alice");
        usdc = new MockUSDC(6);
        router = new TabRouter(address(usdc), treasury, 100);

        usdc.mint(alice.addr, 10_000e6);
        vm.prank(alice.addr);
        usdc.approve(address(router), type(uint256).max);
    }

    /* ------------------------------ helpers ----------------------------- */

    function _signPayment(
        Vm.Wallet memory signer,
        address from,
        address to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = router.hashPayment(from, to, amount, fee, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        return abi.encodePacked(r, s, v);
    }

    /* ----------------------------- happy path --------------------------- */

    function test_RelayPayment_TransfersAmountAndFee() public {
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount); // 1e6 = 1 USDC
        uint256 nonce = 42;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPayment(alice, alice.addr, recipient, amount, fee, nonce, deadline);

        vm.prank(relayer);
        router.relayPayment(alice.addr, recipient, amount, fee, nonce, deadline, sig);

        assertEq(usdc.balanceOf(recipient), amount, "recipient");
        assertEq(usdc.balanceOf(treasury), fee, "treasury");
        assertEq(usdc.balanceOf(alice.addr), 10_000e6 - amount - fee, "sender");
        assertTrue(router.isNonceUsed(alice.addr, nonce));
        assertEq(router.totalVolume(), amount);
        assertEq(router.totalFeesCollected(), fee);
    }

    function test_CalculateFee_OnePercent() public view {
        assertEq(router.calculateFee(100e6), 1e6);
        assertEq(router.calculateFee(1_000e6), 10e6);
        assertEq(router.calculateFee(0), 0);
    }

    function test_RelayPayment_AnyoneCanSubmit() public {
        // Permissionless: stranger relays alice's signed payment.
        uint256 amount = 50e6;
        uint256 fee = router.calculateFee(amount);
        bytes memory sig =
            _signPayment(alice, alice.addr, recipient, amount, fee, 1, block.timestamp + 1);

        vm.prank(stranger);
        router.relayPayment(alice.addr, recipient, amount, fee, 1, block.timestamp + 1, sig);

        assertEq(usdc.balanceOf(recipient), amount);
    }

    /* ------------------------------- reverts ---------------------------- */

    function test_Revert_BadSignature() public {
        Vm.Wallet memory mallory = vm.createWallet("mallory");
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);

        bytes memory badSig =
            _signPayment(mallory, alice.addr, recipient, amount, fee, 1, block.timestamp + 1);

        vm.expectRevert(TabRouter.InvalidSignature.selector);
        router.relayPayment(alice.addr, recipient, amount, fee, 1, block.timestamp + 1, badSig);
    }

    function test_Revert_NonceReplay() public {
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);
        uint256 nonce = 7;
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _signPayment(alice, alice.addr, recipient, amount, fee, nonce, dl);

        router.relayPayment(alice.addr, recipient, amount, fee, nonce, dl, sig);

        vm.expectRevert(TabRouter.NonceAlreadyUsed.selector);
        router.relayPayment(alice.addr, recipient, amount, fee, nonce, dl, sig);
    }

    function test_Revert_ExpiredDeadline() public {
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(alice, alice.addr, recipient, amount, fee, 1, dl);

        vm.warp(dl + 1);
        vm.expectRevert(TabRouter.ExpiredDeadline.selector);
        router.relayPayment(alice.addr, recipient, amount, fee, 1, dl, sig);
    }

    function test_Revert_InvalidFee_TooHigh() public {
        // Relayer tries to trick alice into sending a 10% fee on a payment she
        // only signed for 1%. The contract recomputes and rejects.
        uint256 amount = 100e6;
        uint256 inflatedFee = 10e6;
        bytes memory sig =
            _signPayment(alice, alice.addr, recipient, amount, inflatedFee, 1, block.timestamp + 1);

        vm.expectRevert(TabRouter.InvalidFee.selector);
        router.relayPayment(alice.addr, recipient, amount, inflatedFee, 1, block.timestamp + 1, sig);
    }

    function test_Revert_ZeroAmount() public {
        bytes memory sig = _signPayment(alice, alice.addr, recipient, 0, 0, 1, block.timestamp + 1);
        vm.expectRevert(TabRouter.InvalidAmount.selector);
        router.relayPayment(alice.addr, recipient, 0, 0, 1, block.timestamp + 1, sig);
    }

    function test_Revert_ZeroRecipient() public {
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);
        bytes memory sig =
            _signPayment(alice, alice.addr, address(0), amount, fee, 1, block.timestamp + 1);
        vm.expectRevert(TabRouter.ZeroAddress.selector);
        router.relayPayment(alice.addr, address(0), amount, fee, 1, block.timestamp + 1, sig);
    }

    function test_Revert_TamperedRecipient() public {
        // Alice signs paying recipient, relayer swaps recipient.
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);
        bytes memory sig =
            _signPayment(alice, alice.addr, recipient, amount, fee, 1, block.timestamp + 1);

        vm.expectRevert(TabRouter.InvalidSignature.selector);
        router.relayPayment(alice.addr, stranger, amount, fee, 1, block.timestamp + 1, sig);
    }

    /* -------------------------------- admin ----------------------------- */

    function test_SetTreasury_OnlyOwner() public {
        address newT = makeAddr("newTreasury");
        router.setPlatformTreasury(newT);
        assertEq(router.platformTreasury(), newT);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        router.setPlatformTreasury(treasury);
    }

    function test_Revert_ConstructorZeroAddress() public {
        vm.expectRevert(TabRouter.ZeroAddress.selector);
        new TabRouter(address(0), treasury, 100);

        vm.expectRevert(TabRouter.ZeroAddress.selector);
        new TabRouter(address(usdc), address(0), 100);
    }

    function test_Revert_ConstructorFeeTooHigh() public {
        vm.expectRevert(TabRouter.FeeTooHigh.selector);
        new TabRouter(address(usdc), treasury, 501);
    }

    function test_SetPlatformFee_OnlyOwner() public {
        router.setPlatformFee(200);
        assertEq(router.platformFeeBps(), 200);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        router.setPlatformFee(100);
    }

    function test_SetPlatformFee_RevertsAboveCap() public {
        vm.expectRevert(TabRouter.FeeTooHigh.selector);
        router.setPlatformFee(501);
    }

    function test_Pause_BlocksRelay() public {
        router.pause();
        uint256 amount = 100e6;
        uint256 fee = router.calculateFee(amount);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(alice, alice.addr, makeAddr("to"), amount, fee, 0, deadline);
        vm.expectRevert("Pausable: paused");
        router.relayPayment(alice.addr, makeAddr("to"), amount, fee, 0, deadline, sig);
        router.unpause();
        router.relayPayment(alice.addr, makeAddr("to"), amount, fee, 0, deadline, sig);
    }

    /* -------------------------------- fuzz ------------------------------ */

    function testFuzz_RelayPayment(uint128 amount, uint64 nonce, uint32 dlOffset) public {
        // Cap below 10_000e6 with headroom so amount + fee fits in alice's balance.
        amount = uint128(bound(amount, 1, 9_900e6));
        vm.assume(!router.isNonceUsed(alice.addr, nonce));

        uint256 fee = router.calculateFee(amount);
        uint256 dl = block.timestamp + uint256(dlOffset) + 1;

        bytes memory sig = _signPayment(alice, alice.addr, recipient, amount, fee, nonce, dl);
        router.relayPayment(alice.addr, recipient, amount, fee, nonce, dl, sig);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(treasury), fee);
    }
}
