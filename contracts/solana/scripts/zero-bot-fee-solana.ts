// Set tab-bot Anchor program config.fee_bps = 0 on Solana mainnet.
//
// Effect: bot tips routed through the Solana tab-bot program become free.
// tab-router (Solana merchant/checkout) is untouched — still 1%.
//
//   cd ./
//   ANCHOR_PROVIDER_URL=https://api.mainnet-beta.solana.com \
//   ANCHOR_WALLET=/path/to/your-deployer-keypair.json \
//     npx tsx scripts/zero-bot-fee-solana.ts
//
// The wallet pointed to by ANCHOR_WALLET MUST be config.admin on the
// tab-bot config PDA (i.e. the wallet that ran setup-mainnet.ts).

import * as anchor from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import * as crypto from "crypto";

const TAB_BOT_PROGRAM_ID = new PublicKey(
  "42aU1kQzoXhyPcXb67qrPvQX1Tzx3Uyw4XbfUNF6nEZ8"
);

/** Anchor instruction sighash: sha256("global:<name>")[:8]. */
function sighash(name: string): Buffer {
  return crypto
    .createHash("sha256")
    .update(`global:${name}`)
    .digest()
    .subarray(0, 8);
}

async function main() {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const admin = (provider.wallet as anchor.Wallet).payer;
  console.log(`Admin wallet: ${admin.publicKey.toBase58()}`);

  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("bot_config")],
    TAB_BOT_PROGRAM_ID
  );
  console.log(`Bot config PDA: ${configPda.toBase58()}`);

  // BotConfig layout (verified against programs/tab-bot/src/lib.rs):
  //   discriminator: 8 bytes
  //   admin:         Pubkey (32)
  //   fee_recipient: Pubkey (32)
  //   mint:          Pubkey (32)
  //   fee_bps:       u64 (8)
  //   paused:        bool (1)
  // fee_bps starts at byte 8 + 32*3 = 104.
  const accountInfo = await provider.connection.getAccountInfo(configPda);
  if (!accountInfo) {
    console.error("bot_config PDA not found — was setup-mainnet.ts ever run?");
    process.exit(1);
  }
  const currentBps = accountInfo.data.readBigUInt64LE(104);
  console.log(`Current fee_bps: ${currentBps}`);

  if (currentBps === 0n) {
    console.log("Already 0 — nothing to do.");
    return;
  }

  // Encode set_fee_bps instruction: discriminator + new_bps (u64 LE = 0).
  const data = Buffer.concat([
    sighash("set_fee_bps"),
    Buffer.alloc(8), // 0 as u64 LE
  ]);

  const ix = new anchor.web3.TransactionInstruction({
    programId: TAB_BOT_PROGRAM_ID,
    data,
    keys: [
      { pubkey: configPda, isSigner: false, isWritable: true },
      { pubkey: admin.publicKey, isSigner: true, isWritable: false },
    ],
  });

  const { blockhash, lastValidBlockHeight } =
    await provider.connection.getLatestBlockhash("confirmed");
  const tx = new anchor.web3.Transaction().add(ix);
  tx.recentBlockhash = blockhash;
  tx.feePayer = admin.publicKey;
  tx.sign(admin);

  console.log("Sending set_fee_bps(0)…");
  const sig = await provider.connection.sendRawTransaction(tx.serialize());
  console.log(`tx: ${sig}`);
  await provider.connection.confirmTransaction(
    { signature: sig, blockhash, lastValidBlockHeight },
    "confirmed"
  );

  // Brief wait so the RPC read isn't cached at the pre-tx slot.
  await new Promise((r) => setTimeout(r, 2000));
  const after = await provider.connection.getAccountInfo(configPda);
  const newBps = after!.data.readBigUInt64LE(104);
  console.log(`New fee_bps: ${newBps}`);
  if (newBps !== 0n) {
    console.warn(`WARN: post-tx read shows ${newBps}. Verify on Solscan.`);
    return;
  }
  console.log("Done. Solana bot tips are now free.");
}

void main().catch((e) => {
  console.error(e);
  process.exit(1);
});
