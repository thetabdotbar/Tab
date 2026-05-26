// Set TabBotRouter.platformFeeBps = 0 on every active EVM chain.
//
// Effect: bot tips (Telegram / Discord / Farcaster /tip, /tab send) become
// 100% free. Merchant flows (TabRouter) are untouched — still 1%.
//
//   OWNER_PRIVATE_KEY=0x<deployer-key> npx tsx script/zero-bot-fees-evm.ts
//
// Idempotent. Skips chains where the current fee is already 0.

import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, bsc, celo, ink } from "viem/chains";
import type { Chain } from "viem";

const TAB_BOT_ROUTER: Address = "0xD9663b9a8C097D882bCbE69e811D500f7ad67Bcf";

const CHAINS: Array<{ name: string; chain: Chain; rpc: string }> = [
  { name: "base", chain: base, rpc: process.env.BASE_RPC ?? "https://mainnet.base.org" },
  { name: "bsc", chain: bsc, rpc: process.env.BSC_RPC ?? "https://bsc-dataseed.binance.org" },
  { name: "ink", chain: ink, rpc: process.env.INK_RPC ?? "https://rpc-gel.inkonchain.com" },
  { name: "celo", chain: celo, rpc: process.env.CELO_RPC ?? "https://forno.celo.org" },
];

const ABI = [
  {
    type: "function",
    name: "platformFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "setPlatformFeeBps",
    stateMutability: "nonpayable",
    inputs: [{ name: "newBps", type: "uint256" }],
    outputs: [],
  },
] as const;

async function main() {
  const key = process.env.OWNER_PRIVATE_KEY as Hex | undefined;
  if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) {
    console.error(
      "Set OWNER_PRIVATE_KEY to the deployer wallet that owns TabBotRouter."
    );
    process.exit(1);
  }
  const account = privateKeyToAccount(key);
  console.log(`Owner address: ${account.address}\n`);

  for (const { name, chain, rpc } of CHAINS) {
    console.log(`==> ${name}`);
    const publicClient = createPublicClient({ chain, transport: http(rpc) });
    const walletClient = createWalletClient({ account, chain, transport: http(rpc) });

    try {
      const current = (await publicClient.readContract({
        address: TAB_BOT_ROUTER,
        abi: ABI,
        functionName: "platformFeeBps",
      })) as bigint;
      console.log(`    current platformFeeBps: ${current}`);

      if (current === 0n) {
        console.log(`    already 0, skipping`);
        continue;
      }

      const txHash = await walletClient.writeContract({
        address: TAB_BOT_ROUTER,
        abi: ABI,
        functionName: "setPlatformFeeBps",
        args: [0n],
      });
      console.log(`    tx: ${txHash}`);
      await publicClient.waitForTransactionReceipt({ hash: txHash });

      const after = (await publicClient.readContract({
        address: TAB_BOT_ROUTER,
        abi: ABI,
        functionName: "platformFeeBps",
      })) as bigint;
      console.log(`    new platformFeeBps: ${after}`);
      if (after !== 0n) {
        console.error(`    ERROR: fee did not update to 0 on ${name}`);
        process.exitCode = 1;
      }
    } catch (e) {
      console.error(`    failed on ${name}:`, e instanceof Error ? e.message : e);
      process.exitCode = 1;
    }
    console.log("");
  }

  console.log("Done. Bot tips are now free across all updated chains.");
  console.log("Next: update Solana tab-bot program fee to 0 separately.");
}

void main();
