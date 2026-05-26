// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Tests for v2 gasless entrypoints: createPlanFor + subscribeFor.
/// Legacy paths are covered by TabSubscriptionRouter.t.sol — here we
/// focus on signature verification, nonce replay protection, and
/// deadline expiration.
contract TabSubscriptionRouterV2Test is Test {
    TabSubscriptionRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");

    uint256 internal constant CREATOR_PK = 0xC4EA702;
    uint256 internal constant SUB_PK     = 0x5CB5;
    uint256 internal constant BAD_PK     = 0xBADBAD;
    address internal creator;
    address internal subscriber;

    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant AMOUNT = 10 ether;
    uint64  internal constant PERIOD = uint64(30 days);

    bytes32 internal CREATE_PLAN_TYPEHASH;
    bytes32 internal SUBSCRIBE_TYPEHASH;

    function setUp() public {
        creator = vm.addr(CREATOR_PK);
        subscriber = vm.addr(SUB_PK);

        usdc = new MockUSDC(18);
        router = new TabSubscriptionRouter(IERC20(address(usdc)), treasury, FEE_BPS);

        usdc.mint(subscriber, 1_000 ether);
        vm.prank(subscriber);
        usdc.approve(address(router), type(uint256).max);

        CREATE_PLAN_TYPEHASH = router.CREATE_PLAN_TYPEHASH();
        SUBSCRIBE_TYPEHASH   = router.SUBSCRIBE_TYPEHASH();
    }

    /* ------------------------ createPlanFor ------------------------ */

    function test_CreatePlanFor_HappyPath() public {
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 10 minutes;

        bytes memory sig = _signCreatePlan(CREATOR_PK, creator, "monthly", AMOUNT, PERIOD, nonce, deadline);
        bytes32 planKey = router.createPlanFor(creator, "monthly", AMOUNT, PERIOD, nonce, deadline, sig);

        (address storedCreator, uint256 amount, uint64 period, , bool active) = router.plans(planKey);
        assertEq(storedCreator, creator, "plan creator must be the signer");
        assertEq(amount, AMOUNT);
        assertEq(period, PERIOD);
        assertTrue(active);

        assertTrue(router.isNonceUsed(creator, nonce));
    }

    function test_Revert_CreatePlanFor_BadSig() public {
        bytes memory sig = _signCreatePlan(BAD_PK, creator, "monthly", AMOUNT, PERIOD, 1, block.timestamp + 10 minutes);
        vm.expectRevert(TabSubscriptionRouter.InvalidSignature.selector);
        router.createPlanFor(creator, "monthly", AMOUNT, PERIOD, 1, block.timestamp + 10 minutes, sig);
    }

    function test_Revert_CreatePlanFor_NonceReplay() public {
        uint256 deadline = block.timestamp + 10 minutes;
        bytes memory sig = _signCreatePlan(CREATOR_PK, creator, "monthly", AMOUNT, PERIOD, 1, deadline);
        router.createPlanFor(creator, "monthly", AMOUNT, PERIOD, 1, deadline, sig);

        // Replay the same signed message under a different planId — the
        // nonce is what blocks it, not the plan-already-exists check.
        bytes memory sig2 = _signCreatePlan(CREATOR_PK, creator, "yearly", AMOUNT, PERIOD, 1, deadline);
        vm.expectRevert(TabSubscriptionRouter.NonceAlreadyUsed.selector);
        router.createPlanFor(creator, "yearly", AMOUNT, PERIOD, 1, deadline, sig2);
    }

    function test_Revert_CreatePlanFor_ExpiredDeadline() public {
        uint256 deadline = block.timestamp + 10 minutes;
        bytes memory sig = _signCreatePlan(CREATOR_PK, creator, "monthly", AMOUNT, PERIOD, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(TabSubscriptionRouter.ExpiredDeadline.selector);
        router.createPlanFor(creator, "monthly", AMOUNT, PERIOD, 1, deadline, sig);
    }

    /* ------------------------ subscribeFor ------------------------ */

    function test_SubscribeFor_HappyPath() public {
        // Creator publishes a plan first (gasless path).
        uint256 planNonce = 1;
        uint256 planDeadline = block.timestamp + 10 minutes;
        bytes memory planSig =
            _signCreatePlan(CREATOR_PK, creator, "monthly", AMOUNT, PERIOD, planNonce, planDeadline);
        bytes32 planKey =
            router.createPlanFor(creator, "monthly", AMOUNT, PERIOD, planNonce, planDeadline, planSig);

        // Subscriber subscribes via signature — first period charges
        // from subscriber's USDC, paid to creator + treasury.
        uint256 subNonce = 1;
        uint256 subDeadline = block.timestamp + 10 minutes;
        bytes memory subSig =
            _signSubscribe(SUB_PK, subscriber, planKey, subNonce, subDeadline);
        router.subscribeFor(subscriber, planKey, subNonce, subDeadline, subSig);

        // Funds moved.
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        uint256 net = AMOUNT - fee;
        assertEq(usdc.balanceOf(creator), net, "creator received net");
        assertEq(usdc.balanceOf(treasury), fee, "treasury received fee");
        assertEq(usdc.balanceOf(subscriber), 1_000 ether - AMOUNT, "subscriber debited full amount");

        // Subscription state.
        (bool active, , , , uint256 charges) = router.subs(subscriber, planKey);
        assertTrue(active);
        assertEq(charges, 1);
        assertTrue(router.isNonceUsed(subscriber, subNonce));
    }

    function test_Revert_SubscribeFor_BadSig() public {
        bytes32 planKey = _publishPlan();
        bytes memory sig = _signSubscribe(BAD_PK, subscriber, planKey, 1, block.timestamp + 10 minutes);
        vm.expectRevert(TabSubscriptionRouter.InvalidSignature.selector);
        router.subscribeFor(subscriber, planKey, 1, block.timestamp + 10 minutes, sig);
    }

    function test_Revert_SubscribeFor_NonceReplay() public {
        bytes32 planKey = _publishPlan();
        uint256 deadline = block.timestamp + 10 minutes;
        bytes memory sig = _signSubscribe(SUB_PK, subscriber, planKey, 1, deadline);
        router.subscribeFor(subscriber, planKey, 1, deadline, sig);

        // Same nonce can't be reused even if the user cancels and
        // re-subscribes — they need a fresh nonce.
        vm.prank(subscriber);
        router.cancel(planKey);

        bytes memory sig2 = _signSubscribe(SUB_PK, subscriber, planKey, 1, deadline);
        vm.expectRevert(TabSubscriptionRouter.NonceAlreadyUsed.selector);
        router.subscribeFor(subscriber, planKey, 1, deadline, sig2);
    }

    function test_Revert_SubscribeFor_ExpiredDeadline() public {
        bytes32 planKey = _publishPlan();
        uint256 deadline = block.timestamp + 10 minutes;
        bytes memory sig = _signSubscribe(SUB_PK, subscriber, planKey, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(TabSubscriptionRouter.ExpiredDeadline.selector);
        router.subscribeFor(subscriber, planKey, 1, deadline, sig);
    }

    /* ------------------------ legacy paths ------------------------ */

    function test_Legacy_CreatePlan_StillWorks() public {
        vm.prank(creator);
        bytes32 planKey = router.createPlan("monthly", AMOUNT, PERIOD);
        (address storedCreator, , , , bool active) = router.plans(planKey);
        assertEq(storedCreator, creator);
        assertTrue(active);
    }

    /* ------------------------ helpers ------------------------ */

    function _publishPlan() internal returns (bytes32) {
        vm.prank(creator);
        return router.createPlan("monthly", AMOUNT, PERIOD);
    }

    function _signCreatePlan(
        uint256 pk,
        address signerCreator,
        string memory planId,
        uint256 amount,
        uint64 period,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_PLAN_TYPEHASH,
                signerCreator,
                keccak256(bytes(planId)),
                amount,
                period,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _signSubscribe(
        uint256 pk,
        address signerSubscriber,
        bytes32 planKey,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(SUBSCRIBE_TYPEHASH, signerSubscriber, planKey, nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash));
    }
}
