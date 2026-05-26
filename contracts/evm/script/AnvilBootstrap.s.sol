// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TabRouter} from "../src/TabRouter.sol";
import {TabBotRouter} from "../src/TabBotRouter.sol";
import {TabEscrowRouter} from "../src/TabEscrowRouter.sol";
import {TabSubscriptionRouter} from "../src/TabSubscriptionRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice One-shot local bootstrap. Deploys a mock USDC, both routers, mints
///         test USDC to MINT_RECIPIENT (default: anvil account 0), and prints
///         every address so you can paste them into tab-web/.env.local.
///
/// Run after `anvil --chain-id 31337` is up:
///
///   forge script script/AnvilBootstrap.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Optional env:
///   MINT_RECIPIENT      — address to mint test USDC into. Defaults to anvil acct 0.
///   MINT_AMOUNT_USDC    — how much (in human USDC units). Defaults to 1_000_000.
///   STABLE_DECIMALS     — 6 (USDC) or 18 (USDT-style). Defaults to 6.
///   BOT_FEE_BPS         — initial TabBotRouter fee. Defaults to 100.
contract AnvilBootstrap is Script {
    function run() external {
        uint8 decimals = uint8(vm.envOr("STABLE_DECIMALS", uint256(6)));
        uint256 botFeeBps = vm.envOr("BOT_FEE_BPS", uint256(100));
        address mintRecipient = vm.envOr(
            "MINT_RECIPIENT",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) // anvil acct 0
        );
        uint256 mintAmountInUnits = vm.envOr("MINT_AMOUNT_USDC", uint256(1_000_000));
        uint256 mintAmountWei = mintAmountInUnits * (10 ** decimals);

        vm.startBroadcast();

        // 1. Mock USDC.
        MockUSDC stable = new MockUSDC(decimals);

        // 2. Routers — deployer is treasury + initial executor (same as deploy.sh).
        address deployer = msg.sender;
        TabRouter router = new TabRouter(address(stable), deployer, botFeeBps);
        TabBotRouter bot = new TabBotRouter(address(stable), deployer, botFeeBps, deployer);
        TabEscrowRouter escrow = new TabEscrowRouter(
            address(stable),
            deployer,
            botFeeBps,
            deployer
        );
        TabSubscriptionRouter sub = new TabSubscriptionRouter(
            IERC20(address(stable)),
            deployer,
            botFeeBps
        );

        // 3. Fund the recipient so they can immediately pay.
        stable.mint(mintRecipient, mintAmountWei);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Tab local bootstrap complete ===");
        console2.log("Add the following to tab-web/.env.local:");
        console2.log("");
        console2.log("NEXT_PUBLIC_TAB_ROUTER_ANVIL=", address(router));
        console2.log("NEXT_PUBLIC_TAB_BOT_ROUTER_ANVIL=", address(bot));
        console2.log("NEXT_PUBLIC_TAB_ESCROW_ROUTER_ANVIL=", address(escrow));
        console2.log("NEXT_PUBLIC_TAB_SUBSCRIPTION_ROUTER_ANVIL=", address(sub));
        console2.log("NEXT_PUBLIC_USDC_ANVIL=", address(stable));
        console2.log("NEXT_PUBLIC_RPC_ANVIL=http://127.0.0.1:8545");
        console2.log("");
        console2.log("Treasury / executor:", deployer);
        console2.log("Funded address:     ", mintRecipient);
        console2.log("Funded amount:      ", mintAmountInUnits, "stablecoin units");
    }
}
