// One-shot init for the Personal Subscription program.
// Calls `initialize(fee_bps=0)` on the deployed program, creating the
// `SubConfig` PDA with admin = deployer wallet, fee_recipient = the
// existing Solana treasury, mint = USDC. After this, plan create /
// subscribe / charge all work the same way they do on the business
// program — just with the fee_bps_snapshot = 0 on every plan.
//
// Run from ./:
//   node scripts/init-personal-sub.mjs

import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const PROGRAM_ID = new PublicKey(
  "DpQSpSdnwRB1p7iK1b5TbL1F5YqtimGd9g32jWc4WyB7"
);
const USDC_MINT = new PublicKey(
  "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
);
const FEE_RECIPIENT = new PublicKey(
  "552531jSitQndRiiQK89ZshxvvRbEzSekQoniWpjSBr"
);
const RPC_URL = "https://api.mainnet-beta.solana.com";

function loadKeypair(p) {
  const expanded = p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
  const bytes = JSON.parse(fs.readFileSync(expanded, "utf8"));
  return Keypair.fromSecretKey(Uint8Array.from(bytes));
}

function anchorDiscriminator(name) {
  // First 8 bytes of sha256(`global:<name>`).
  return crypto.createHash("sha256").update(`global:${name}`).digest().slice(0, 8);
}

function u64LE(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n));
  return b;
}

async function main() {
  const admin = loadKeypair("~/.config/solana/tab-deployer.json");
  console.log("Admin:", admin.publicKey.toBase58());

  const [configPda, bump] = PublicKey.findProgramAddressSync(
    [Buffer.from("sub_config")],
    PROGRAM_ID
  );
  console.log("Config PDA:", configPda.toBase58(), "bump:", bump);

  const data = Buffer.concat([anchorDiscriminator("initialize"), u64LE(0)]);

  const ix = new TransactionInstruction({
    programId: PROGRAM_ID,
    data,
    keys: [
      { pubkey: configPda, isSigner: false, isWritable: true },
      { pubkey: USDC_MINT, isSigner: false, isWritable: false },
      { pubkey: FEE_RECIPIENT, isSigner: false, isWritable: false },
      { pubkey: admin.publicKey, isSigner: true, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
  });

  const conn = new Connection(RPC_URL, "confirmed");
  const tx = new Transaction().add(ix);
  tx.feePayer = admin.publicKey;
  const { blockhash, lastValidBlockHeight } = await conn.getLatestBlockhash(
    "confirmed"
  );
  tx.recentBlockhash = blockhash;
  tx.sign(admin);

  console.log("Submitting…");
  const sig = await conn.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    preflightCommitment: "confirmed",
  });
  console.log("Signature:", sig);
  await conn.confirmTransaction(
    { signature: sig, blockhash, lastValidBlockHeight },
    "confirmed"
  );
  console.log("Confirmed.");
  console.log("");
  console.log("Personal Subscription Program initialized:");
  console.log("  Program ID:    ", PROGRAM_ID.toBase58());
  console.log("  Config PDA:    ", configPda.toBase58());
  console.log("  Fee BPS:       0");
  console.log("  Fee Recipient: ", FEE_RECIPIENT.toBase58());
  console.log("  USDC Mint:     ", USDC_MINT.toBase58());
  console.log("  Admin:         ", admin.publicKey.toBase58());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
