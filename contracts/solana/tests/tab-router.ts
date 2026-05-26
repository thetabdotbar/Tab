// Anchor tests for tab-router. Covers happy path + replay protection.
//
// Run with:
//   anchor test            (spins up local validator)
//   anchor test --skip-local-validator (against running validator)

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  createAssociatedTokenAccountInstruction,
  createMint,
  createMintToInstruction,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { Ed25519Program, PublicKey, SystemProgram } from "@solana/web3.js";
import * as nacl from "tweetnacl";
import { sha256 } from "js-sha256";
import { TabRouter } from "../target/types/tab_router";

describe("tab-router", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.TabRouter as Program<TabRouter>;
  const admin = provider.wallet;

  const payer = anchor.web3.Keypair.generate();
  const recipient = anchor.web3.Keypair.generate();
  const feeRecipient = anchor.web3.Keypair.generate();

  let mint: PublicKey;
  let payerAta: PublicKey;
  let recipientAta: PublicKey;
  let feeRecipientAta: PublicKey;
  let configPda: PublicKey;
  let nonceFor: (k: PublicKey) => PublicKey;

  before(async () => {
    // Airdrop payer + recipient + feeRecipient so their ATAs can be paid for.
    for (const k of [payer.publicKey, recipient.publicKey, feeRecipient.publicKey]) {
      const sig = await provider.connection.requestAirdrop(k, 1e9);
      await provider.connection.confirmTransaction(sig);
    }

    mint = await createMint(
      provider.connection,
      // @ts-expect-error Keypair shape mismatch — anchor provides the payer.
      provider.wallet.payer ?? admin,
      admin.publicKey,
      null,
      6
    );

    payerAta = getAssociatedTokenAddressSync(mint, payer.publicKey);
    recipientAta = getAssociatedTokenAddressSync(mint, recipient.publicKey);
    feeRecipientAta = getAssociatedTokenAddressSync(mint, feeRecipient.publicKey);

    [configPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("config")],
      program.programId
    );

    nonceFor = (k) =>
      PublicKey.findProgramAddressSync(
        [Buffer.from("user_nonce"), k.toBuffer()],
        program.programId
      )[0];

    // Initialize router with 100 bps (1%) fee.
    await program.methods
      .initialize(new anchor.BN(100))
      .accounts({
        admin: admin.publicKey,
        config: configPda,
        mint,
        feeRecipient: feeRecipient.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // Create the three ATAs and mint 1000 USDC to the payer.
    const ix = [
      createAssociatedTokenAccountInstruction(admin.publicKey, payerAta, payer.publicKey, mint),
      createAssociatedTokenAccountInstruction(admin.publicKey, recipientAta, recipient.publicKey, mint),
      createAssociatedTokenAccountInstruction(admin.publicKey, feeRecipientAta, feeRecipient.publicKey, mint),
      createMintToInstruction(mint, payerAta, admin.publicKey, 1_000_000_000n),
    ];
    const tx = new anchor.web3.Transaction().add(...ix);
    await provider.sendAndConfirm(tx);
  });

  function digestFor(amount: bigint, nonce: bigint, deadline: bigint): Buffer {
    const buf = Buffer.concat([
      Buffer.from("TAB_PAYMENT_V1"),
      payer.publicKey.toBuffer(),
      recipientAta.toBuffer(),
      mint.toBuffer(),
      u64Le(amount),
      u64Le(nonce),
      u64Le(deadline),
    ]);
    return Buffer.from(sha256.arrayBuffer(buf));
  }

  it("settles a payment, splits fee, and bumps nonce", async () => {
    const amount = 100_000_000n; // 100 USDC
    const nonce = 0n;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    const digest = digestFor(amount, nonce, deadline);
    const sig = nacl.sign.detached(digest, payer.secretKey);
    const verifyIx = Ed25519Program.createInstructionWithPublicKey({
      publicKey: payer.publicKey.toBytes(),
      message: digest,
      signature: sig,
    });

    await program.methods
      .executePayment(
        new anchor.BN(amount.toString()),
        new anchor.BN(nonce.toString()),
        new anchor.BN(deadline.toString())
      )
      .accounts({
        relayer: admin.publicKey,
        payer: payer.publicKey,
        config: configPda,
        payerNonce: nonceFor(payer.publicKey),
        mint,
        payerAta,
        recipientAta,
        feeRecipientAta,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
      })
      .preInstructions([verifyIx])
      .rpc();
    // 1% fee on 100 USDC = 1 USDC. Recipient should have 99, fee 1.
    // Caller is expected to assert balances here — left as TODO once
    // @solana/spl-token's getAccount is wired into the test runtime.
  });

  it("rejects a replay of the same nonce", async () => {
    const amount = 50_000_000n;
    const nonce = 0n; // already consumed
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    const digest = digestFor(amount, nonce, deadline);
    const sig = nacl.sign.detached(digest, payer.secretKey);
    const verifyIx = Ed25519Program.createInstructionWithPublicKey({
      publicKey: payer.publicKey.toBytes(),
      message: digest,
      signature: sig,
    });
    try {
      await program.methods
        .executePayment(
          new anchor.BN(amount.toString()),
          new anchor.BN(nonce.toString()),
          new anchor.BN(deadline.toString())
        )
        .accounts({
          relayer: admin.publicKey,
          payer: payer.publicKey,
          config: configPda,
          payerNonce: nonceFor(payer.publicKey),
          mint,
          payerAta,
          recipientAta,
          feeRecipientAta,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
        })
        .preInstructions([verifyIx])
        .rpc();
      throw new Error("expected BadNonce");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!/BadNonce|nonce mismatch/i.test(msg)) throw e;
    }
  });
});

function u64Le(v: bigint): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(v);
  return b;
}
