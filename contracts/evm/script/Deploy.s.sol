// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabRouter} from "../src/TabRouter.sol";
import {TabBotRouter} from "../src/TabBotRouter.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";

/// @notice Deploys the full Tab router suite on one chain.
///
/// Env vars (set per chain before running):
///   STABLE_ADDRESS       - the stablecoin to settle in (USDC on Base, USDT on BSC, USDT0 on Ink, ...)
///   TREASURY_ADDRESS     - fee receiver (platform multisig)
///   EXECUTOR_ADDRESS     - off-chain executor that calls TabBotRouter + TabEscrowRouter
///   ROUTER_FEE_BPS       - TabRouter fee in bps (0..500), default 100
///   BOT_FEE_BPS          - TabBotRouter fee in bps (0..500), default 100
///   ESCROW_FEE_BPS       - TabEscrowRouter fee in bps (0..500), default 100
///   SUB_FEE_BPS          - TabSubscriptionRouter fee in bps (0..500), default 100
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $RPC \
///     --broadcast \
///     --private-key $PK \
///     --verify --etherscan-api-key $ETHERSCAN_KEY
contract Deploy is Script {
    function run() external {
        address stable = vm.envAddress("STABLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");
        uint256 routerFeeBps = vm.envOr("ROUTER_FEE_BPS", uint256(100));
        uint256 botFeeBps = vm.envOr("BOT_FEE_BPS", uint256(100));
        uint256 escrowFeeBps = vm.envOr("ESCROW_FEE_BPS", uint256(100));
        uint256 subFeeBps = vm.envOr("SUB_FEE_BPS", uint256(100));

        vm.startBroadcast();
        TabRouter router = new TabRouter(stable, treasury, routerFeeBps);
        TabBotRouter bot = new TabBotRouter(stable, treasury, botFeeBps, executor);
        TabEscrowRouter escrow = new TabEscrowRouter(stable, treasury, escrowFeeBps, executor);
        TabSubscriptionRouter sub = new TabSubscriptionRouter(IERC20(stable), treasury, subFeeBps);
        vm.stopBroadcast();

        console2.log("=== Tab Router Suite Deployed ===");
        console2.log("TabRouter             :", address(router));
        console2.log("TabBotRouter          :", address(bot));
        console2.log("TabEscrowRouter       :", address(escrow));
        console2.log("TabSubscriptionRouter :", address(sub));
        console2.log("---");
        console2.log("Stable                :", stable);
        console2.log("Treasury              :", treasury);
        console2.log("Executor              :", executor);
        console2.log("Router fee (bps)      :", routerFeeBps);
        console2.log("Bot fee (bps)         :", botFeeBps);
        console2.log("Escrow fee (bps)      :", escrowFeeBps);
        console2.log("Subscription fee (bps):", subFeeBps);
    }
}
