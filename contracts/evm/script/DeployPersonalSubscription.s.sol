// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";

/// @notice Deploys a fee-free copy of TabSubscriptionRouter — the
///         "Personal Subscription Router".
///
/// Why: creators publishing recurring plans on Tab are usually thinking
/// of them as personal ("my paid newsletter", "my Patreon-style tip
/// jar"). A 1% take on every monthly charge would feel like a tax. By
/// deploying a second router with feeBps = 0 alongside the existing 1%
/// business router, the workspace tag on the plan controls which one
/// gets used and the fee is structural rather than a database toggle.
///
/// Deployer: use the same deployer wallet as the v2 suite. Each chain
/// will produce a different contract address (since that wallet has
/// different nonces per chain) — the frontend reads them via per-chain
/// env vars (NEXT_PUBLIC_TAB_SUBSCRIPTION_ROUTER_PERSONAL_BASE etc),
/// exactly like the existing Business sub router addresses.
///
/// Env vars:
///   STABLE_ADDRESS       - stablecoin to settle in (must match the
///                          existing TabSubscriptionRouter on this chain)
///   TREASURY_ADDRESS     - fee receiver. Required by the constructor
///                          even though we deploy with fee=0 — set it
///                          to the same treasury as the business router
///                          so admin can never accidentally drain to a
///                          fresh address if they later flip the fee.
///
/// Usage:
///   forge script script/DeployPersonalSubscription.s.sol \
///     --rpc-url $RPC --broadcast \
///     --private-key $PERSONAL_SUB_DEPLOYER_PK \
///     --verify --etherscan-api-key $ETHERSCAN_KEY
contract DeployPersonalSubscription is Script {
    function run() external {
        address stable = vm.envAddress("STABLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        // Fee tier is the *defining* property of this deployment.
        // Hard-coded so an env-var typo can't accidentally deploy a
        // Personal Subscription Router with a non-zero fee. If you ever
        // want a non-zero personal sub fee, change this line and
        // re-deploy with a fresh deployer wallet.
        uint256 personalSubFeeBps = 0;

        vm.startBroadcast();
        TabSubscriptionRouter personalSub = new TabSubscriptionRouter(
            IERC20(stable),
            treasury,
            personalSubFeeBps
        );
        vm.stopBroadcast();

        console2.log("=== Tab Personal Subscription Router Deployed ===");
        console2.log("TabSubscriptionRouter (Personal):", address(personalSub));
        console2.log("---");
        console2.log("Stable                          :", stable);
        console2.log("Treasury                        :", treasury);
        console2.log("Fee (bps)                       :", personalSubFeeBps);
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Copy this address into tab-web/lib/contracts.ts");
        console2.log("   as NEXT_PUBLIC_TAB_SUBSCRIPTION_ROUTER_PERSONAL_<CHAIN>.");
        console2.log("2. Keep the existing TabSubscriptionRouter v2 as the");
        console2.log("   Business sub router at 1%. Set");
        console2.log("   NEXT_PUBLIC_TAB_SUBSCRIPTION_ROUTER_BUSINESS_<CHAIN>");
        console2.log("   to that address so the lookup is explicit.");
        console2.log("3. Personal-workspace plans will publish through this");
        console2.log("   address automatically once env vars are live.");
    }
}
