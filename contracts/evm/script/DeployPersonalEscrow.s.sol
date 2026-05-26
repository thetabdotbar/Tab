// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";

/// @notice Deploys a fee-free copy of TabEscrowRouter — the
/// "Personal Escrow Router", dedicated to bot-relayed P2P tips so the
/// recipient claims exactly what the sender intended (no skim).
///
/// Mirror of DeployPersonal.s.sol but for the escrow surface:
///   - Business OpenTabs (sender-initiated, can hold large amounts) →
///     existing TabEscrowRouter at 1% fee. Already live; no changes.
///   - Personal/tip escrows (bot relays a /tip to an unlinked user) →
///     THIS deployment with fee = 0 bps. The relay is short-lived (24h
///     default) and small-value (chat tips), so a 1% take felt wrong
///     when linked-user tips already pay 0% via TabBotRouter.
///
/// Why a separate contract vs. flipping the fee on the existing one:
/// the existing router holds merchant OpenTabs that DO pay 1% (and
/// `setPlatformFee` only affects new escrows, not snapshotted ones).
/// Per-contract fee tiers keep the routing predictable and remove any
/// "did the admin change the fee?" doubt — each contract enforces its
/// own fee for its full life.
///
/// Env vars:
///   STABLE_ADDRESS    - stablecoin to settle in. MUST match the
///                       existing TabEscrowRouter on this chain so the
///                       relayer wallet doesn't need separate USDC
///                       allowances per contract.
///   TREASURY_ADDRESS  - fee receiver. Required by the constructor
///                       even though we deploy with fee=0, so the
///                       admin can never accidentally drain to a fresh
///                       address if they ever flip the fee later. Use
///                       the same treasury as the business router.
///   EXECUTOR_ADDRESS  - the bot's executor wallet (same address that's
///                       already registered on TabBotRouter as an
///                       executor). Constructor adds it to the
///                       executors mapping so the relay path can
///                       call claimByCodeFor immediately after deploy.
///
/// Deployer: use the same deployer wallet as the v1 suite (same nonce
/// pattern → predictable address per chain). Each chain produces a
/// different contract address (deployer nonces differ across chains).
///
/// Usage:
///   STABLE_ADDRESS=0x... TREASURY_ADDRESS=0x... EXECUTOR_ADDRESS=0x... \
///   forge script script/DeployPersonalEscrow.s.sol \
///     --rpc-url $RPC --broadcast \
///     --private-key $DEPLOYER_PK \
///     --verify --etherscan-api-key $ETHERSCAN_KEY
///
/// Post-deploy:
///   1. Copy the printed address into tab-web/lib/contracts.ts as
///      NEXT_PUBLIC_TAB_ESCROW_PERSONAL_<CHAIN> (or the canonical
///      hardcoded constant if every chain lands on the same address).
///   2. tab-web's /api/bot/escrow-relay will pick this up automatically
///      via escrowRouterPersonalFor(chain) — no other changes needed.
///   3. The existing TabEscrowRouter stays untouched as the Business
///      escrow router at 1% for sender-initiated OpenTabs.
contract DeployPersonalEscrow is Script {
    function run() external {
        address stable = vm.envAddress("STABLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");

        // Fee tier is the defining property of this deployment. Hard-
        // coded to 0 here instead of read from env so an env typo can
        // never accidentally deploy a Personal Escrow with a non-zero
        // fee. If you ever want a non-zero personal escrow fee, change
        // this line explicitly + redeploy.
        uint256 personalFeeBps = 0;

        vm.startBroadcast();
        TabEscrowRouter personal =
            new TabEscrowRouter(stable, treasury, personalFeeBps, executor);
        vm.stopBroadcast();

        console2.log("=== Tab Personal Escrow Router Deployed ===");
        console2.log("TabEscrowRouter (Personal):", address(personal));
        console2.log("---");
        console2.log("Stable                    :", stable);
        console2.log("Treasury                  :", treasury);
        console2.log("Executor                  :", executor);
        console2.log("Fee (bps)                 :", personalFeeBps);
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Copy this address into tab-web/lib/contracts.ts");
        console2.log("   as NEXT_PUBLIC_TAB_ESCROW_PERSONAL_<CHAIN>.");
        console2.log("2. The existing TabEscrowRouter stays as the Business");
        console2.log("   escrow router at 1%.");
        console2.log("3. The bot-relay endpoint at /api/bot/escrow-relay");
        console2.log("   reads escrowRouterPersonalFor(chain) and will");
        console2.log("   route relay tips through this address.");
    }
}
