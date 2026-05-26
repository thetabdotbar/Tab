// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TabBotRouter} from "../src/TabBotRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TabBotRouterTest is Test {
    TabBotRouter internal router;
    MockUSDC internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sponsor = makeAddr("sponsor");

    uint256 internal constant DEFAULT_FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC(18); // mirror BSC USDT decimals
        router = new TabBotRouter(address(usdc), treasury, DEFAULT_FEE_BPS, executor);

        usdc.mint(alice, 10_000 ether);
        usdc.mint(sponsor, 1_000_000 ether);

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(sponsor);
        usdc.approve(address(router), type(uint256).max);
    }

    /* --------------------------------- p2p ------------------------------- */

    function test_ExecuteP2P_TransfersNetAndFee() public {
        uint256 amount = 100 ether;
        (uint256 fee, uint256 net) = router.calculateFee(amount);
        assertEq(fee, 1 ether);
        assertEq(net, 99 ether);

        vm.prank(executor);
        router.executeP2P(alice, bob, amount, 0, "tweet:1");

        assertEq(usdc.balanceOf(bob), net);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(alice), 10_000 ether - amount);
        assertEq(router.nonces(alice), 1);
        assertTrue(router.isTweetUsed("tweet:1"));
    }

    function test_ExecuteP2P_NonceCounterAdvances() public {
        vm.startPrank(executor);
        router.executeP2P(alice, bob, 10 ether, 0, "t1");
        router.executeP2P(alice, bob, 10 ether, 1, "t2");
        router.executeP2P(alice, bob, 10 ether, 2, "t3");
        vm.stopPrank();
        assertEq(router.nonces(alice), 3);
    }

    function test_Revert_ExecuteP2P_NotExecutor() public {
        vm.prank(stranger);
        vm.expectRevert(TabBotRouter.NotExecutor.selector);
        router.executeP2P(alice, bob, 1 ether, 0, "t");
    }

    function test_Revert_ExecuteP2P_BadNonce() public {
        vm.prank(executor);
        vm.expectRevert(TabBotRouter.InvalidNonce.selector);
        router.executeP2P(alice, bob, 1 ether, 5, "t");
    }

    function test_Revert_ExecuteP2P_TweetReplay() public {
        vm.startPrank(executor);
        router.executeP2P(alice, bob, 1 ether, 0, "same");
        vm.expectRevert(TabBotRouter.TweetIdAlreadyUsed.selector);
        router.executeP2P(alice, bob, 1 ether, 1, "same");
        vm.stopPrank();
    }

    function test_Revert_ExecuteP2P_EmptyTweetId() public {
        vm.prank(executor);
        vm.expectRevert(TabBotRouter.EmptyId.selector);
        router.executeP2P(alice, bob, 1 ether, 0, "");
    }

    function test_Revert_ExecuteP2P_ZeroAmount() public {
        vm.prank(executor);
        vm.expectRevert(TabBotRouter.InvalidAmount.selector);
        router.executeP2P(alice, bob, 0, 0, "t");
    }

    function test_Revert_ExecuteP2P_ZeroAddress() public {
        vm.startPrank(executor);
        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        router.executeP2P(address(0), bob, 1 ether, 0, "t");
        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        router.executeP2P(alice, address(0), 1 ether, 0, "t2");
        vm.stopPrank();
    }

    /* -------------------------------- grants ----------------------------- */

    function test_ExecuteGrant_TransfersAndDedups() public {
        uint256 amount = 500 ether;
        (uint256 fee, uint256 net) = router.calculateFee(amount);

        vm.prank(executor);
        router.executeGrant(sponsor, bob, amount, "campaign-launch-2026");

        assertEq(usdc.balanceOf(bob), net);
        assertEq(usdc.balanceOf(treasury), fee);
        assertTrue(router.isGrantIssued("campaign-launch-2026", bob));

        vm.prank(executor);
        vm.expectRevert(TabBotRouter.GrantAlreadyIssued.selector);
        router.executeGrant(sponsor, bob, amount, "campaign-launch-2026");
    }

    function test_ExecuteGrant_DifferentRecipientsAllowed() public {
        vm.startPrank(executor);
        router.executeGrant(sponsor, bob, 10 ether, "c1");
        router.executeGrant(sponsor, alice, 10 ether, "c1");
        vm.stopPrank();
    }

    function test_Revert_ExecuteGrant_NotExecutor() public {
        vm.prank(stranger);
        vm.expectRevert(TabBotRouter.NotExecutor.selector);
        router.executeGrant(sponsor, bob, 1 ether, "c");
    }

    function test_Revert_ExecuteGrant_EmptyCampaign() public {
        vm.prank(executor);
        vm.expectRevert(TabBotRouter.EmptyId.selector);
        router.executeGrant(sponsor, bob, 1 ether, "");
    }

    /* --------------------------------- admin ----------------------------- */

    function test_AddRemoveExecutor() public {
        address newExec = makeAddr("newExec");
        router.addExecutor(newExec);
        assertTrue(router.executors(newExec));

        vm.prank(newExec);
        router.executeP2P(alice, bob, 1 ether, 0, "t-new");

        router.removeExecutor(newExec);
        assertFalse(router.executors(newExec));

        vm.prank(newExec);
        vm.expectRevert(TabBotRouter.NotExecutor.selector);
        router.executeP2P(alice, bob, 1 ether, 1, "t-after");
    }

    function test_SetPlatformFee_RespectsCap() public {
        router.setPlatformFee(500);
        assertEq(router.platformFeeBps(), 500);

        vm.expectRevert(TabBotRouter.FeeTooHigh.selector);
        router.setPlatformFee(501);
    }

    function test_SetPlatformFee_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        router.setPlatformFee(50);
    }

    function test_SetPlatformTreasury() public {
        address newT = makeAddr("newT");
        router.setPlatformTreasury(newT);
        assertEq(router.platformTreasury(), newT);

        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        router.setPlatformTreasury(address(0));
    }

    function test_Revert_ConstructorFeeTooHigh() public {
        vm.expectRevert(TabBotRouter.FeeTooHigh.selector);
        new TabBotRouter(address(usdc), treasury, 501, executor);
    }

    function test_Revert_ConstructorZeroAddresses() public {
        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        new TabBotRouter(address(0), treasury, 100, executor);
        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        new TabBotRouter(address(usdc), address(0), 100, executor);
        vm.expectRevert(TabBotRouter.ZeroAddress.selector);
        new TabBotRouter(address(usdc), treasury, 100, address(0));
    }

    /* --------------------------------- fuzz ------------------------------ */

    function testFuzz_FeeMath(uint128 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        router.setPlatformFee(feeBps);

        (uint256 fee, uint256 net) = router.calculateFee(amount);
        assertEq(fee + net, amount);
        assertEq(fee, (uint256(amount) * feeBps) / 10_000);
    }
}
