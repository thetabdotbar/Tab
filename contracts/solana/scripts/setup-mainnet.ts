/**
 * One-shot on-chain setup for the deployed Tab Solana programs.
 *
 * Idempotent: checks each `config` PDA before calling `initialize`, and uses
 * `init_if_needed` for executor PDAs so re-running is safe.
 *
 * What it does, per program:
 *
 *   tab-escrow       → initialize(config, mint=USDC, fee_recipient=deployer, fee_bps=100)
 *                    → add_executor(deployer)
 *   tab-subscription → initialize(config, mint=USDC, fee_recipient=deployer, fee_bps=100)
 *   tab-bot          → initialize(config, mint=USDC, fee_recipient=deployer, fee_bps=100)
 *                    → add_executor(deployer)
 *   tab-router       → NOT handled here (use migrations/deploy.ts; different PDA seeds)
 *
 * Why no Anchor client: we built the programs with `--no-idl` (proc-macro2
 * upstream deprecation broke IDL extraction), so this script encodes
 * instructions by hand using the well-known Anchor discriminator scheme
 * (sha256("global:<snake_case_name>")[0..8] + borsh args).
 *
 * Usage (from repo root):
 *
 *   yarn add -D tsx
 *   npx tsx scripts/setup-mainnet.ts
 *
 * Required env:
 *
 *   ANCHOR_WALLET   path to the deployer keypair JSON (defaults to
 *                   ~/.config/solana/tab-deployer.json)
 *   RPC_URL         optional override; defaults to public mainnet-beta
 *   TAB_USDC_MINT   optional override; defaults to canonical USDC mint
 */

import {
  ComputeBudgetProgram,
  Connection,
  Keypair,
  PublicKey,
  sendAndConfirmTransaction,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PROGRAMS = {
  escrow: {
    id: new PublicKey("FTpukPZPKix4N6Po8obUTwnDvyMqwAqo4EaDFyCnJjMd"),
    configSeed: "escrow_config",
    hasExecutors: true,
  },
  subscription: {
    id: new PublicKey("Ex1hBmDhmz8hZ7oYy4BKtt5jstEMCoeeshEA51swbXZa"),
    configSeed: "sub_config",
    hasExecutors: false,
  },
  bot: {
    id: new PublicKey("42aU1kQzoXhyPcXb67qrPvQX1Tzx3Uyw4XbfUNF6nEZ8"),
    configSeed: "bot_config",
    hasExecutors: true,
  },
} as const;

// 1% (100 bps) — same as EVM defaults.
const FEE_BPS = 100n;

const RPC_URL = process.env.RPC_URL ?? "https://api.mainnet-beta.solana.com";

const USDC_MINT = new PublicKey(
  process.env.TAB_USDC_MINT ??
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" // canonical Circle USDC
);

const WALLET_PATH =
  process.env.ANCHOR_WALLET ??
  join(homedir(), ".config", "solana", "tab-deployer.json");

/* ----------------------------- helpers -------------------------------- */

function loadKeypair(path: string): Keypair {
  const raw = readFileSync(path, "utf8").trim();
  if (!raw.startsWith("[")) {
    throw new Error(
      `Wallet file ${path} doesn't look like a Solana JSON-array keypair`
    );
  }
  const arr = JSON.parse(raw) as number[];
  return Keypair.fromSecretKey(Uint8Array.from(arr));
}

function disc(method: string): Buffer {
  return createHash("sha256")
    .update(`global:${method}`)
    .digest()
    .subarray(0, 8);
}

function u64(n: bigint): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(n, 0);
  return b;
}

function configPda(programId: PublicKey, seed: string): PublicKey {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from(seed)],
    programId
  );
  return pda;
}

function executorPda(programId: PublicKey, executor: PublicKey): PublicKey {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from("executor"), executor.toBuffer()],
    programId
  );
  return pda;
}

async function accountExists(
  conn: Connection,
  pubkey: PublicKey
): Promise<boolean> {
  const info = await conn.getAccountInfo(pubkey, "confirmed");
  return info !== null;
}

function bumpCompute(): TransactionInstruction[] {
  return [
    ComputeBudgetProgram.setComputeUnitLimit({ units: 600_000 }),
    ComputeBudgetProgram.setComputeUnitPrice({ microLamports: 1_000 }),
  ];
}

async function send(
  conn: Connection,
  signer: Keypair,
  ixs: TransactionInstruction[]
): Promise<string> {
  const tx = new Transaction();
  for (const ix of bumpCompute()) tx.add(ix);
  for (const ix of ixs) tx.add(ix);
  tx.feePayer = signer.publicKey;
  const { blockhash } = await conn.getLatestBlockhash("confirmed");
  tx.recentBlockhash = blockhash;
  return sendAndConfirmTransaction(conn, tx, [signer], {
    commitment: "confirmed",
  });
}

/* ------------------------- instruction builders ----------------------- */

function buildInitializeIx(opts: {
  programId: PublicKey;
  configSeed: string;
  admin: PublicKey;
  mint: PublicKey;
  feeRecipient: PublicKey;
  feeBps: bigint;
}): TransactionInstruction {
  const config = configPda(opts.programId, opts.configSeed);
  return new TransactionInstruction({
    programId: opts.programId,
    data: Buffer.concat([disc("initialize"), u64(opts.feeBps)]),
    keys: [
      { pubkey: config, isSigner: false, isWritable: true },
      { pubkey: opts.mint, isSigner: false, isWritable: false },
      { pubkey: opts.feeRecipient, isSigner: false, isWritable: false },
      { pubkey: opts.admin, isSigner: true, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
  });
}

function buildAddExecutorIx(opts: {
  programId: PublicKey;
  configSeed: string;
  admin: PublicKey;
  executor: PublicKey;
}): TransactionInstruction {
  const config = configPda(opts.programId, opts.configSeed);
  const executorEntry = executorPda(opts.programId, opts.executor);
  // add_executor uses `#[instruction(executor_key: Pubkey)]` for PDA seed
  // derivation. The pubkey is appended after the discriminator.
  return new TransactionInstruction({
    programId: opts.programId,
    data: Buffer.concat([disc("add_executor"), opts.executor.toBuffer()]),
    keys: [
      { pubkey: config, isSigner: false, isWritable: false },
      { pubkey: executorEntry, isSigner: false, isWritable: true },
      { pubkey: opts.admin, isSigner: true, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
  });
}

/* --------------------------------- main ------------------------------- */

async function main() {
  const conn = new Connection(RPC_URL, "confirmed");
  const deployer = loadKeypair(WALLET_PATH);
  console.log("Deployer:", deployer.publicKey.toBase58());
  console.log("RPC:     ", RPC_URL);
  console.log("USDC:    ", USDC_MINT.toBase58());
  console.log("Fee bps: ", FEE_BPS.toString());
  console.log("");

  // The deployer's SOL balance has to cover rent for any new PDAs we create
  // (3x configs + 2x executor entries = ~0.02 SOL). Bail if obviously empty
  // to give a clear error rather than a cryptic on-chain InsufficientFunds.
  const balanceLamports = await conn.getBalance(deployer.publicKey);
  console.log(`Deployer balance: ${(balanceLamports / 1e9).toFixed(4)} SOL`);
  if (balanceLamports < 50_000_000) {
    throw new Error(
      "Deployer wallet has <0.05 SOL — top it up before running setup."
    );
  }
  console.log("");

  for (const [name, info] of Object.entries(PROGRAMS)) {
    console.log(`── ${name} (${info.id.toBase58()}) ──`);

    // 1. initialize, if not already done.
    const cfg = configPda(info.id, info.configSeed);
    const alreadyInit = await accountExists(conn, cfg);
    if (alreadyInit) {
      console.log(`  ✓ config already exists at ${cfg.toBase58()}`);
    } else {
      console.log(`  → initialize → config=${cfg.toBase58()}`);
      const sig = await send(conn, deployer, [
        buildInitializeIx({
          programId: info.id,
          configSeed: info.configSeed,
          admin: deployer.publicKey,
          mint: USDC_MINT,
          feeRecipient: deployer.publicKey,
          feeBps: FEE_BPS,
        }),
      ]);
      console.log(`    initialized — sig=${sig}`);
    }

    // 2. add_executor(deployer), if relevant.
    if (info.hasExecutors) {
      const entry = executorPda(info.id, deployer.publicKey);
      const exists = await accountExists(conn, entry);
      if (exists) {
        console.log(`  ✓ executor already registered at ${entry.toBase58()}`);
      } else {
        console.log(`  → add_executor(${deployer.publicKey.toBase58()})`);
        const sig = await send(conn, deployer, [
          buildAddExecutorIx({
            programId: info.id,
            configSeed: info.configSeed,
            admin: deployer.publicKey,
            executor: deployer.publicKey,
          }),
        ]);
        console.log(`    executor added — sig=${sig}`);
      }
    }
    console.log("");
  }

  console.log("✓ All Tab Solana programs initialized + executors registered.");
  console.log("");
  console.log("Next: set SOLANA_EXECUTOR_PRIVATE_KEY in Vercel to the contents");
  console.log(`of ${WALLET_PATH}, then redeploy tab-web.`);
}

main().catch((e) => {
  console.error("");
  console.error("✗ Setup failed:", e instanceof Error ? e.message : e);
  process.exit(1);
});
