// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TabSubscriptionRouterTest is Test {
    TabSubscriptionRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal creator  = makeAddr("creator");
    address internal alice    = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant FEE_BPS = 100;       // 1%
    uint256 internal constant AMOUNT  = 10 ether;  // 10 USDC per period
    uint64  internal constant PERIOD  = 30 days;

    bytes32 internal planKey;
    string  internal constant PLAN_ID = "discord_silver";

    function setUp() public {
        usdc = new MockUSDC(18);
        router = new TabSubscriptionRouter(usdc, treasury, FEE_BPS);

        vm.prank(creator);
        planKey = router.createPlan(PLAN_ID, AMOUNT, PERIOD);

        usdc.mint(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    /* ----------------------------- plan ----------------------------- */

    function test_CreatePlan_HasCorrectKeyAndFields() public {
        bytes32 expected = router.planKeyOf(creator, PLAN_ID);
        assertEq(planKey, expected);
        (address c, uint256 amt, uint64 per, uint16 fb, bool active) = router.plans(planKey);
        assertEq(c, creator);
        assertEq(amt, AMOUNT);
        assertEq(per, PERIOD);
        assertEq(uint256(fb), FEE_BPS);
        assertTrue(active);
    }

    function test_Revert_CreatePlan_Duplicate() public {
        vm.prank(creator);
        vm.expectRevert(TabSubscriptionRouter.PlanExists.selector);
        router.createPlan(PLAN_ID, AMOUNT, PERIOD);
    }

    function test_Revert_CreatePlan_ZeroAmount() public {
        vm.prank(creator);
        vm.expectRevert(TabSubscriptionRouter.InvalidAmount.selector);
        router.createPlan("plan_zero", 0, PERIOD);
    }

    function test_Revert_CreatePlan_PeriodTooShort() public {
        vm.prank(creator);
        vm.expectRevert(TabSubscriptionRouter.InvalidPeriod.selector);
        router.createPlan("plan_fast", AMOUNT, uint64(30 minutes));
    }

    function test_Revert_CreatePlan_PeriodTooLong() public {
        vm.prank(creator);
        vm.expectRevert(TabSubscriptionRouter.InvalidPeriod.selector);
        router.createPlan("plan_slow", AMOUNT, uint64(366 days));
    }

    function test_DifferentCreatorsCanReusePlanId() public {
        address other = makeAddr("other");
        vm.prank(other);
        bytes32 otherKey = router.createPlan(PLAN_ID, AMOUNT, PERIOD);
        assertTrue(otherKey != planKey);
    }

    /* ---------------------------- subscribe ------------------------- */

    function test_Subscribe_ChargesFirstPeriod() public {
        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        uint256 net = AMOUNT - fee;

        vm.prank(alice);
        router.subscribe(planKey);

        (bool active,, uint64 lastChargedAt,, uint256 chargesPaid) = router.subs(alice, planKey);
        assertTrue(active);
        assertEq(lastChargedAt, block.timestamp);
        assertEq(chargesPaid, 1);

        assertEq(usdc.balanceOf(creator), net);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(alice), 1_000 ether - AMOUNT);
    }

    function test_Revert_Subscribe_Twice() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.prank(alice);
        vm.expectRevert(TabSubscriptionRouter.AlreadySubscribed.selector);
        router.subscribe(planKey);
    }

    function test_Revert_Subscribe_InactivePlan() public {
        vm.prank(creator);
        router.deactivatePlan(planKey);

        vm.prank(alice);
        vm.expectRevert(TabSubscriptionRouter.PlanInactive.selector);
        router.subscribe(planKey);
    }

    /* ------------------------------ charge -------------------------- */

    function test_Charge_AdvancesAfterPeriod() public {
        vm.prank(alice);
        router.subscribe(planKey);

        // jump exactly to the next period
        vm.warp(block.timestamp + PERIOD);
        router.charge(planKey, alice); // permissionless caller

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        uint256 net = AMOUNT - fee;

        assertEq(usdc.balanceOf(creator), net * 2);
        assertEq(usdc.balanceOf(treasury), fee * 2);

        (,, uint64 lastChargedAt,, uint256 chargesPaid) = router.subs(alice, planKey);
        assertEq(lastChargedAt, block.timestamp);
        assertEq(chargesPaid, 2);
    }

    function test_Revert_Charge_TooEarly() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.warp(block.timestamp + PERIOD - 1);
        vm.expectRevert(TabSubscriptionRouter.TooEarly.selector);
        router.charge(planKey, alice);
    }

    function test_Revert_Charge_AfterCancel() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.prank(alice);
        router.cancel(planKey);

        vm.warp(block.timestamp + PERIOD);
        vm.expectRevert(TabSubscriptionRouter.NotSubscribed.selector);
        router.charge(planKey, alice);
    }

    function test_Revert_Charge_PlanDeactivated() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.prank(creator);
        router.deactivatePlan(planKey);

        vm.warp(block.timestamp + PERIOD);
        vm.expectRevert(TabSubscriptionRouter.PlanInactive.selector);
        router.charge(planKey, alice);
    }

    function test_Charge_Permissionless() public {
        // A stranger (e.g. anyone running a cron) can settle Alice's charge.
        vm.prank(alice);
        router.subscribe(planKey);

        vm.warp(block.timestamp + PERIOD);
        vm.prank(stranger);
        router.charge(planKey, alice);

        (,, uint64 lastChargedAt,,) = router.subs(alice, planKey);
        assertEq(lastChargedAt, block.timestamp);
    }

    function test_Charge_HaltsWhenAllowanceRevoked() public {
        vm.prank(alice);
        router.subscribe(planKey);

        // Alice revokes the allowance, simulating loss of funds.
        vm.prank(alice);
        usdc.approve(address(router), 0);

        vm.warp(block.timestamp + PERIOD);
        vm.expectRevert(); // SafeERC20 / underlying transferFrom revert
        router.charge(planKey, alice);
    }

    /* --------------------------- cancel + revert -------------------- */

    function test_Cancel_StopsSubscription() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.prank(alice);
        router.cancel(planKey);

        (bool active,,, uint64 cancelledAt,) = router.subs(alice, planKey);
        assertFalse(active);
        assertEq(cancelledAt, block.timestamp);
    }

    function test_Revert_Cancel_NeverSubscribed() public {
        vm.prank(alice);
        vm.expectRevert(TabSubscriptionRouter.NotSubscribed.selector);
        router.cancel(planKey);
    }

    /* ------------------------------- admin -------------------------- */

    function test_OwnerCanSetFee() public {
        router.setPlatformFee(200);
        assertEq(router.platformFeeBps(), 200);
    }

    function test_Revert_OwnerSetFeeAboveCap() public {
        vm.expectRevert(TabSubscriptionRouter.FeeTooHigh.selector);
        router.setPlatformFee(600);
    }

    function test_Revert_NonOwnerSetFee() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        router.setPlatformFee(200);
    }

    /* ------------------------------ views --------------------------- */

    function test_IsChargeable_FalseBeforePeriod() public {
        vm.prank(alice);
        router.subscribe(planKey);
        assertFalse(router.isChargeable(planKey, alice));
    }

    function test_IsChargeable_TrueAfterPeriod() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.warp(block.timestamp + PERIOD);
        assertTrue(router.isChargeable(planKey, alice));
    }

    function test_IsChargeable_FalseAfterCancel() public {
        vm.prank(alice);
        router.subscribe(planKey);
        vm.warp(block.timestamp + PERIOD);
        vm.prank(alice);
        router.cancel(planKey);
        assertFalse(router.isChargeable(planKey, alice));
    }

    /* ------------------------------ fuzz ---------------------------- */

    function testFuzz_FeeMath(uint128 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        amount = uint128(bound(amount, 1, type(uint128).max));
        router.setPlatformFee(feeBps);
        uint256 fee = router.feeOf(amount);
        assertEq(fee, (uint256(amount) * feeBps) / 10_000);
    }
}
