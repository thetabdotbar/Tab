// One-shot deploy script. Usage: `anchor deploy && ts-node migrations/deploy.ts`
//
// Requires NEXT_PUBLIC_USDC_DEVNET (or equivalent) to be set so the initial
// `initialize` call can pin the SPL mint the router operates on.

import * as anchor from "@coral-xyz/anchor";
import { PublicKey, SystemProgram } from "@solana/web3.js";

module.exports = async function (provider: anchor.AnchorProvider) {
  anchor.setProvider(provider);
  const program = anchor.workspace.TabRouter as anchor.Program;

  const usdcMint = new PublicKey(
    process.env.TAB_SOLANA_USDC_MINT ??
      // USDC on devnet — pin a different mint per environment.
      "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  );

  const feeRecipient = new PublicKey(
    process.env.TAB_SOLANA_FEE_RECIPIENT ?? provider.wallet.publicKey.toBase58()
  );

  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("config")],
    program.programId
  );

  await program.methods
    .initialize(new anchor.BN(100)) // 1% fee
    .accounts({
      admin: provider.wallet.publicKey,
      config: configPda,
      mint: usdcMint,
      feeRecipient,
      systemProgram: SystemProgram.programId,
    })
    .rpc();

  console.log("✓ TabRouter initialized");
  console.log("  program:", program.programId.toBase58());
  console.log("  config :", configPda.toBase58());
  console.log("  mint   :", usdcMint.toBase58());
};
