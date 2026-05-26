// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";

/// @notice Deploys ONLY the v2 (gasless) router pair on one chain.
///
/// Why a separate script: TabRouter + TabBotRouter v1 are unchanged in
/// v2 — only TabEscrowRouter and TabSubscriptionRouter got the new
/// EIP-712 `*For` entrypoints. Re-deploying the unchanged pair would
/// waste gas and burn a vanity nonce slot we don't need.
///
/// Address-parity trick: same as v1. Use a FRESH deployer wallet (zero
/// prior history on every target chain), run this script in the same
/// order on every chain. Each contract lands at the same address
/// everywhere because the deployer's nonce sequence matches:
///   nonce 0 → TabEscrowRouter v2
///   nonce 1 → TabSubscriptionRouter v2
///
/// Env vars (mirror Deploy.s.sol):
///   STABLE_ADDRESS       - USDC/USDT/USDT0/cUSD address on this chain
///   TREASURY_ADDRESS     - fee receiver (platform multisig)
///   EXECUTOR_ADDRESS     - off-chain executor that calls the new
///                          createEscrowFor* entrypoints
///   ESCROW_FEE_BPS       - default 100
///   SUB_FEE_BPS          - default 100
///
/// Usage:
///   forge script script/DeployV2.s.sol \
///     --rpc-url $RPC --broadcast \
///     --private-key $V2_DEPLOYER_PK \
///     --verify --etherscan-api-key $ETHERSCAN_KEY
contract DeployV2 is Script {
    function run() external {
        address stable = vm.envAddress("STABLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");
        uint256 escrowFeeBps = vm.envOr("ESCROW_FEE_BPS", uint256(100));
        uint256 subFeeBps = vm.envOr("SUB_FEE_BPS", uint256(100));

        vm.startBroadcast();
        TabEscrowRouter escrow = new TabEscrowRouter(stable, treasury, escrowFeeBps, executor);
        TabSubscriptionRouter sub = new TabSubscriptionRouter(IERC20(stable), treasury, subFeeBps);
        vm.stopBroadcast();

        console2.log("=== Tab Gasless v2 Deployed ===");
        console2.log("TabEscrowRouter v2       :", address(escrow));
        console2.log("TabSubscriptionRouter v2 :", address(sub));
        console2.log("---");
        console2.log("Stable                   :", stable);
        console2.log("Treasury                 :", treasury);
        console2.log("Executor                 :", executor);
        console2.log("Escrow fee (bps)         :", escrowFeeBps);
        console2.log("Subscription fee (bps)   :", subFeeBps);
        console2.log("");
        console2.log("Reminder: copy both addresses into tab-web/lib/contracts.ts");
        console2.log("(DEPLOYED_TAB_ESCROW_ROUTER + DEPLOYED_TAB_SUBSCRIPTION_ROUTER)");
        console2.log("then set NEXT_PUBLIC_GASLESS_V2=true on Vercel.");
    }
}
