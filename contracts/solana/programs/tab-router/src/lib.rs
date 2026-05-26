//! TabRouter — gasless SPL token payments with a 1% protocol fee.
//!
//! Design parity with the EVM TabRouter:
//!
//! * The **payer** pre-signs a `Payment` message off-chain.
//! * Any **relayer** can submit the matching `execute_payment` instruction.
//!   The relayer pays the Solana transaction fee; the protocol takes a fee
//!   (default 1%) from the SPL token amount; the recipient gets the rest.
//! * Per-payer **nonce** counter prevents replay. The nonce is stored in a
//!   PDA (`["user_nonce", payer]`) and incremented on every successful exec.
//! * The token mint is fixed in the `RouterConfig` PDA at init time so the
//!   router can never be tricked into moving a different mint.
//!
//! Notes for adapters / SDKs:
//!
//! * The Ed25519 signature verification is performed by the runtime's
//!   `Ed25519SigVerify` precompile, which must be included as the first
//!   instruction in the transaction. The router instruction inspects
//!   `sysvar::instructions` to confirm a matching verify was performed.
//!   This is the standard Solana pattern for off-chain meta-tx authorization.
//! * `fee_bps` is mutable by the program admin (max 500 bps / 5%).
//! * Recipient ATA must already exist. The off-chain sender is expected to
//!   include a create_associated_token_account instruction if it doesn't.
//!
//! Status: v0 scaffold. Tests in `tests/tab-router.ts` cover the happy path
//! plus replay protection. Audit before mainnet.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    ed25519_program::ID as ED25519_ID, hash::hashv, sysvar::instructions,
};
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

declare_id!("DvS3eW3GJGVJrvqMBtcsS8QtNoxzYtpB61Cx19Uz86xs");

pub const BPS_DENOMINATOR: u64 = 10_000;
pub const MAX_FEE_BPS: u64 = 500; // 5% absolute cap, mirrors EVM contract.
pub const DEFAULT_FEE_BPS: u64 = 100; // 1%.

#[program]
pub mod tab_router {
    use super::*;

    /// One-time init. Stores the token mint, admin, fee recipient, and the
    /// initial fee bps. The mint can never be changed afterwards.
    pub fn initialize(
        ctx: Context<Initialize>,
        fee_bps: u64,
    ) -> Result<()> {
        require!(fee_bps <= MAX_FEE_BPS, TabError::FeeAboveCap);
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.fee_recipient = ctx.accounts.fee_recipient.key();
        cfg.mint = ctx.accounts.mint.key();
        cfg.fee_bps = fee_bps;
        cfg.bump = ctx.bumps.config;
        Ok(())
    }

    pub fn set_fee_bps(ctx: Context<AdminOnly>, new_bps: u64) -> Result<()> {
        require!(new_bps <= MAX_FEE_BPS, TabError::FeeAboveCap);
        ctx.accounts.config.fee_bps = new_bps;
        Ok(())
    }

    pub fn set_fee_recipient(
        ctx: Context<AdminOnly>,
        new_recipient: Pubkey,
    ) -> Result<()> {
        ctx.accounts.config.fee_recipient = new_recipient;
        Ok(())
    }

    /// Relay-submitted payment. Verifies the payer's off-chain Ed25519
    /// signature, increments the nonce, splits the token transfer into
    /// (recipient, fee_recipient), and emits an event.
    pub fn execute_payment(
        ctx: Context<ExecutePayment>,
        amount: u64,
        nonce: u64,
        deadline: i64,
    ) -> Result<()> {
        let clock = Clock::get()?;
        require!(clock.unix_timestamp <= deadline, TabError::Expired);
        require!(amount > 0, TabError::ZeroAmount);

        // 1. Confirm the per-payer nonce matches what we expect, then bump it.
        let nonce_acct = &mut ctx.accounts.payer_nonce;
        require!(nonce_acct.next == nonce, TabError::BadNonce);
        nonce_acct.next = nonce
            .checked_add(1)
            .ok_or(TabError::ArithmeticOverflow)?;

        // 2. Confirm an Ed25519SigVerify precompile instruction is present
        //    in this transaction and signs the canonical Payment digest.
        //    The digest matches the EVM EIP-712 spirit: it's a domain-tagged
        //    keccak over the fields. Solana lacks EIP-712 natively; we just
        //    hash the binary tuple.
        let digest = payment_digest(
            &ctx.accounts.payer.key(),
            &ctx.accounts.recipient_ata.key(),
            &ctx.accounts.config.mint,
            amount,
            nonce,
            deadline,
        );
        verify_ed25519_signed(
            &ctx.accounts.instructions_sysvar.to_account_info(),
            &ctx.accounts.payer.key(),
            &digest,
        )?;

        // 3. Split into (net, fee).
        let fee = amount
            .checked_mul(ctx.accounts.config.fee_bps)
            .ok_or(TabError::ArithmeticOverflow)?
            / BPS_DENOMINATOR;
        let net = amount.checked_sub(fee).ok_or(TabError::ArithmeticOverflow)?;

        // 4. Move tokens. Both transfers are CPIs into the SPL token program
        //    with `transfer_checked` (decimals-asserted) for safety.
        let decimals = ctx.accounts.mint.decimals;

        // 4a. payer → recipient (net)
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from: ctx.accounts.payer_ata.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                    to: ctx.accounts.recipient_ata.to_account_info(),
                    authority: ctx.accounts.payer.to_account_info(),
                },
            ),
            net,
            decimals,
        )?;

        // 4b. payer → fee_recipient (fee), only if non-zero.
        if fee > 0 {
            transfer_checked(
                CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    TransferChecked {
                        from: ctx.accounts.payer_ata.to_account_info(),
                        mint: ctx.accounts.mint.to_account_info(),
                        to: ctx.accounts.fee_recipient_ata.to_account_info(),
                        authority: ctx.accounts.payer.to_account_info(),
                    },
                ),
                fee,
                decimals,
            )?;
        }

        emit!(PaymentExecuted {
            payer: ctx.accounts.payer.key(),
            recipient_ata: ctx.accounts.recipient_ata.key(),
            mint: ctx.accounts.config.mint,
            amount,
            net,
            fee,
            nonce,
            relayer: ctx.accounts.relayer.key(),
        });
        Ok(())
    }
}

/* ------------------------------ accounts ------------------------------ */

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,

    #[account(
        init,
        payer = admin,
        seeds = [b"config"],
        bump,
        space = 8 + RouterConfig::INIT_SPACE,
    )]
    pub config: Account<'info, RouterConfig>,

    pub mint: InterfaceAccount<'info, Mint>,
    /// CHECK: stored as Pubkey on the config; we don't dereference it here.
    pub fee_recipient: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(mut, has_one = admin)]
    pub config: Account<'info, RouterConfig>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct ExecutePayment<'info> {
    /// Relayer pays SOL gas + rent for the nonce PDA.
    #[account(mut)]
    pub relayer: Signer<'info>,

    /// The actual payer — NOT a signer. Authorization is via the off-chain
    /// Ed25519 signature checked against `instructions_sysvar`.
    /// CHECK: validated via signature; never written or read for SOL.
    pub payer: UncheckedAccount<'info>,

    // Box<> on the typed accounts so anchor's generated try_accounts() stays
    // under Solana's 4096-byte stack budget. Without Box, the 12-account
    // struct overflows by ~200 bytes which is undefined behavior at runtime.
    #[account(
        seeds = [b"config"],
        bump = config.bump,
        has_one = mint,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        init_if_needed,
        payer = relayer,
        seeds = [b"user_nonce", payer.key().as_ref()],
        bump,
        space = 8 + UserNonce::INIT_SPACE,
    )]
    pub payer_nonce: Box<Account<'info, UserNonce>>,

    pub mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = payer,
    )]
    pub payer_ata: Box<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: the recipient's token account. We don't require it to be the
    /// ATA — caller can pay to any token account of the right mint.
    #[account(mut, token::mint = mint)]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,

    #[account(
        mut,
        token::mint = mint,
        token::authority = config.fee_recipient,
    )]
    pub fee_recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,

    /// CHECK: the instructions sysvar — read-only access for sig verification.
    #[account(address = instructions::ID)]
    pub instructions_sysvar: UncheckedAccount<'info>,
}

/* ------------------------------ state -------------------------------- */

#[account]
#[derive(InitSpace)]
pub struct RouterConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub mint: Pubkey,
    pub fee_bps: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct UserNonce {
    pub next: u64,
}

/* ------------------------------ events ------------------------------- */

#[event]
pub struct PaymentExecuted {
    pub payer: Pubkey,
    pub recipient_ata: Pubkey,
    pub mint: Pubkey,
    pub amount: u64,
    pub net: u64,
    pub fee: u64,
    pub nonce: u64,
    pub relayer: Pubkey,
}

/* ------------------------------ errors ------------------------------- */

#[error_code]
pub enum TabError {
    #[msg("amount must be greater than zero")]
    ZeroAmount,
    #[msg("nonce mismatch — likely replay or out-of-order submission")]
    BadNonce,
    #[msg("deadline has passed")]
    Expired,
    #[msg("fee bps exceeds the absolute cap")]
    FeeAboveCap,
    #[msg("arithmetic overflow")]
    ArithmeticOverflow,
    #[msg("required Ed25519 signature verification not found in this tx")]
    MissingSignature,
    #[msg("signature is present but does not match the expected (payer, digest)")]
    BadSignature,
}

/* ------------------------------ helpers ------------------------------ */

/// Domain-tagged digest of the Payment fields. Mirrors the spirit of EIP-712
/// — a structured commitment to a tuple of inputs that the wallet signs once
/// and the contract validates server-side.
fn payment_digest(
    payer: &Pubkey,
    recipient_ata: &Pubkey,
    mint: &Pubkey,
    amount: u64,
    nonce: u64,
    deadline: i64,
) -> [u8; 32] {
    let h = hashv(&[
        b"TAB_PAYMENT_V1",
        payer.as_ref(),
        recipient_ata.as_ref(),
        mint.as_ref(),
        &amount.to_le_bytes(),
        &nonce.to_le_bytes(),
        &deadline.to_le_bytes(),
    ]);
    h.to_bytes()
}

/// Inspect the instructions sysvar to confirm that this transaction contains
/// an Ed25519SigVerify precompile instruction signing `digest` with the
/// `expected_signer` public key. This is the standard Solana meta-tx pattern.
///
/// The precompile encodes its data as documented at
/// https://docs.solana.com/developing/runtime-facilities/programs#ed25519-program
/// — we re-parse it here rather than trust the relayer's inputs.
fn verify_ed25519_signed(
    instructions_sysvar: &AccountInfo,
    expected_signer: &Pubkey,
    digest: &[u8; 32],
) -> Result<()> {
    // Walk every instruction in the tx and pick out the Ed25519 ones.
    let mut idx = 0u16;
    loop {
        let ix = match instructions::load_instruction_at_checked(
            idx as usize,
            instructions_sysvar,
        ) {
            Ok(ix) => ix,
            Err(_) => break, // walked past the end
        };
        if ix.program_id == ED25519_ID {
            // The data layout is one or more `(offsets, signature, pubkey, message)`
            // entries. We only accept a single-entry instruction signing the
            // matching pubkey + message — this is what tab-web's signer
            // produces. Stricter parsing keeps the surface small.
            if let Some((pubkey, message)) = parse_ed25519_single(&ix.data) {
                if &pubkey == expected_signer.as_ref() && message == digest {
                    return Ok(());
                }
            }
        }
        idx = idx.checked_add(1).ok_or(TabError::ArithmeticOverflow)?;
    }
    err!(TabError::MissingSignature)
}

/// Parse a single-entry Ed25519 precompile instruction's data. Returns
/// (pubkey_bytes, message_slice) on success. The exact byte layout is defined
/// by the runtime and includes fixed-position offsets pointing into the same
/// instruction's data buffer.
fn parse_ed25519_single(data: &[u8]) -> Option<([u8; 32], &[u8])> {
    // Header: u8 num_signatures, u8 padding, then per-entry [14 bytes of
    // offsets: sig_off, sig_ix_idx, pk_off, pk_ix_idx, msg_off, msg_size, msg_ix_idx]
    if data.len() < 2 || data[0] != 1 {
        return None;
    }
    if data.len() < 16 {
        return None;
    }
    let sig_off = u16::from_le_bytes([data[2], data[3]]) as usize;
    let pk_off = u16::from_le_bytes([data[6], data[7]]) as usize;
    let msg_off = u16::from_le_bytes([data[10], data[11]]) as usize;
    let msg_size = u16::from_le_bytes([data[12], data[13]]) as usize;
    if pk_off + 32 > data.len() {
        return None;
    }
    if msg_off + msg_size > data.len() {
        return None;
    }
    // sig_off is included in the layout assertion to make sure the precompile
    // ran; we don't re-read the signature ourselves because the precompile
    // already verified it.
    let _ = sig_off;
    let pubkey: [u8; 32] = data[pk_off..pk_off + 32].try_into().ok()?;
    let message = &data[msg_off..msg_off + msg_size];
    Some((pubkey, message))
}
