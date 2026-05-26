// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TabRouter} from "../src/TabRouter.sol";

/// @notice Deploys a fee-free copy of TabRouter — the "Personal Router".
///
/// Two-wallet model: Tab routes payments through different router
/// contracts based on workspace.
///   - Business workspace (POS, API checkouts) → existing TabRouter at
///     1% fee. Already live; no changes.
///   - Personal workspace (P2P pay, tips, friends) → THIS deployment
///     with fee = 0 bps. Buyer pays exactly what was signed; nothing
///     skimmed.
///
/// Why a separate contract vs. flipping the fee on the existing one:
/// the fee is owner-configurable, but flipping it would change pricing
/// for *every* payment flow including merchant checkouts. We want the
/// fee tier to be implicit in *which contract* the payment runs
/// through, not a global toggle that the owner can change in either
/// direction. Each contract enforces its own fee; nothing to forge.
///
/// Deployer: use the same deployer wallet as the v1 suite. Each chain
/// will produce a different contract address (since that wallet has
/// different nonces per chain) — the frontend reads them via per-chain
/// env vars (NEXT_PUBLIC_TAB_ROUTER_PERSONAL_BASE etc), exactly like
/// the existing Business TabRouter addresses.
///
/// Env vars:
///   STABLE_ADDRESS       - stablecoin to settle in (must match the
///                          existing TabRouter on this chain so users
///                          don't have to maintain two ERC-20 allowances)
///   TREASURY_ADDRESS     - fee receiver. Required by the constructor
///                          even though we deploy with fee=0 — set it
///                          to the same treasury as the business router
///                          so admin can never accidentally drain to a
///                          fresh address if they later flip the fee.
///
/// Usage:
///   forge script script/DeployPersonal.s.sol \
///     --rpc-url $RPC --broadcast \
///     --private-key $PERSONAL_DEPLOYER_PK \
///     --verify --etherscan-api-key $ETHERSCAN_KEY
contract DeployPersonal is Script {
    function run() external {
        address stable = vm.envAddress("STABLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        // Fee tier is the *defining* property of this deployment.
        // Hard-coded here instead of read from env so an env-var typo
        // can't accidentally deploy a Personal Router with a non-zero
        // fee. If you ever want a non-zero personal fee, change this
        // line explicitly + re-deploy with a fresh deployer wallet.
        uint256 personalFeeBps = 0;

        vm.startBroadcast();
        TabRouter personal = new TabRouter(stable, treasury, personalFeeBps);
        vm.stopBroadcast();

        console2.log("=== Tab Personal Router Deployed ===");
        console2.log("TabRouter (Personal) :", address(personal));
        console2.log("---");
        console2.log("Stable               :", stable);
        console2.log("Treasury             :", treasury);
        console2.log("Fee (bps)            :", personalFeeBps);
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Copy this address into tab-web/lib/contracts.ts");
        console2.log("   as NEXT_PUBLIC_TAB_ROUTER_PERSONAL_<CHAIN>.");
        console2.log("2. The existing TabRouter stays as the Business");
        console2.log("   router at 1%. Set NEXT_PUBLIC_TAB_ROUTER_BUSINESS_<CHAIN>");
        console2.log("   to the existing address so the lookup is explicit.");
        console2.log("3. Personal-workspace payments will route through this");
        console2.log("   address automatically once env vars are live.");
    }
}
