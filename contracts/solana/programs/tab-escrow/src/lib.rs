//! TabEscrow — non-custodial open-tab escrow on Solana.
//!
//! Mirrors the EVM `TabEscrowRouter` semantics. Two flows:
//!
//! 1. **Handle escrow** — sender locks tokens against a Tab handle. An
//!    off-chain executor releases the funds to the recipient's wallet
//!    after off-chain verification that the recipient owns that handle.
//!    Use case: pre-coordinated sends between Tab users.
//!
//! 2. **Code escrow** — sender locks tokens against a secret (claim code).
//!    The secret lives in a share link. Anyone who reveals the secret to
//!    `claim_code` gets the funds in their own wallet. Use case:
//!    "send to anyone, no Tab account required" — giveaways, Cryptic-
//!    style tipping, paying contractors who don't have a wallet yet.
//!
//! Both flows support sender refund after the deadline (pull pattern;
//! anyone can trigger to keep the executor key out of the refund path).
//!
//! Fee is **snapshotted on each escrow at creation** — later admin fee
//! changes don't retroactively change an existing escrow's fee. Same
//! design as the updated EVM contract.
//!
//! Pause halts new escrow creation only. Existing escrows can always
//! be claimed and refunded — user funds are never trapped by a pause.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hashv;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

declare_id!("FTpukPZPKix4N6Po8obUTwnDvyMqwAqo4EaDFyCnJjMd");

pub const BPS_DENOMINATOR: u64 = 10_000;
pub const MAX_FEE_BPS: u64 = 500; // 5% cap
pub const MIN_DEADLINE_WINDOW_SECS: i64 = 3_600; // 1h
pub const MAX_DEADLINE_WINDOW_SECS: i64 = 90 * 24 * 3_600; // 90 days

#[program]
pub mod tab_escrow {
    use super::*;

    /// One-time init. Stores admin, fee recipient, mint, fee bps.
    pub fn initialize(ctx: Context<Initialize>, fee_bps: u64) -> Result<()> {
        require!(fee_bps <= MAX_FEE_BPS, TabError::FeeAboveCap);
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.fee_recipient = ctx.accounts.fee_recipient.key();
        cfg.mint = ctx.accounts.mint.key();
        cfg.fee_bps = fee_bps;
        cfg.paused = false;
        cfg.bump = ctx.bumps.config;
        Ok(())
    }

    pub fn set_fee_bps(ctx: Context<AdminOnly>, new_bps: u64) -> Result<()> {
        require!(new_bps <= MAX_FEE_BPS, TabError::FeeAboveCap);
        ctx.accounts.config.fee_bps = new_bps;
        Ok(())
    }

    pub fn set_fee_recipient(ctx: Context<AdminOnly>, new_recipient: Pubkey) -> Result<()> {
        ctx.accounts.config.fee_recipient = new_recipient;
        Ok(())
    }

    pub fn pause(ctx: Context<AdminOnly>) -> Result<()> {
        ctx.accounts.config.paused = true;
        Ok(())
    }

    pub fn unpause(ctx: Context<AdminOnly>) -> Result<()> {
        ctx.accounts.config.paused = false;
        Ok(())
    }

    pub fn add_executor(ctx: Context<AddExecutor>) -> Result<()> {
        let exec = &mut ctx.accounts.executor;
        exec.allowed = true;
        exec.bump = ctx.bumps.executor;
        Ok(())
    }

    pub fn remove_executor(ctx: Context<RemoveExecutor>) -> Result<()> {
        ctx.accounts.executor.allowed = false;
        Ok(())
    }

    /// Lock `amount` of mint against a HANDLE. Recipient must own that
    /// Tab handle when they claim — executor enforces this off-chain.
    pub fn create_escrow_handle(
        ctx: Context<CreateEscrow>,
        handle_hash: [u8; 32],
        amount: u64,
        deadline: i64,
        sender_nonce: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(handle_hash != [0u8; 32], TabError::EmptyCommitment);
        _create_escrow(ctx, handle_hash, amount, deadline, sender_nonce, ClaimType::Handle)
    }

    /// Lock `amount` of mint against a SECRET. Anyone who reveals the
    /// secret to `claim_code` claims the funds. No handle required —
    /// recipient doesn't even need a Tab account.
    pub fn create_escrow_code(
        ctx: Context<CreateEscrow>,
        code_hash: [u8; 32],
        amount: u64,
        deadline: i64,
        sender_nonce: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(code_hash != [0u8; 32], TabError::EmptyCommitment);
        _create_escrow(ctx, code_hash, amount, deadline, sender_nonce, ClaimType::Code)
    }

    /// Executor releases a HANDLE escrow to `recipient`. The executor
    /// MUST have verified off-chain that `recipient` owns the handle.
    /// This program only enforces the hash match + executor allowlist.
    pub fn claim_handle(
        ctx: Context<ClaimHandle>,
        handle_preimage: Vec<u8>,
    ) -> Result<()> {
        let escrow = &mut ctx.accounts.escrow;
        require!(escrow.status == Status::Pending, TabError::EscrowNotPending);
        require!(escrow.claim_type == ClaimType::Handle, TabError::WrongClaimType);
        require!(
            Clock::get()?.unix_timestamp <= escrow.deadline,
            TabError::EscrowExpired
        );
        let computed: [u8; 32] = hashv(&[&handle_preimage]).to_bytes();
        require!(computed == escrow.commitment, TabError::CommitmentMismatch);

        _settle(
            escrow,
            &ctx.accounts.escrow_vault,
            &ctx.accounts.recipient_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }

    /// Anyone with the secret can call this to claim a CODE escrow.
    /// Funds go to the caller's associated token account.
    pub fn claim_code(ctx: Context<ClaimCode>, secret: Vec<u8>) -> Result<()> {
        let escrow = &mut ctx.accounts.escrow;
        require!(escrow.status == Status::Pending, TabError::EscrowNotPending);
        require!(escrow.claim_type == ClaimType::Code, TabError::WrongClaimType);
        require!(
            Clock::get()?.unix_timestamp <= escrow.deadline,
            TabError::EscrowExpired
        );
        let computed: [u8; 32] = hashv(&[&secret]).to_bytes();
        require!(computed == escrow.commitment, TabError::CommitmentMismatch);

        _settle(
            escrow,
            &ctx.accounts.escrow_vault,
            &ctx.accounts.recipient_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }

    /// Sponsored CODE claim — executor presents the secret on behalf of
    /// `recipient`. Used when the recipient has no native SOL for gas
    /// (giveaway / airdrop / tipbot UX where Tab covers the claim cost).
    pub fn claim_code_for(ctx: Context<ClaimCodeFor>, secret: Vec<u8>) -> Result<()> {
        let escrow = &mut ctx.accounts.escrow;
        require!(escrow.status == Status::Pending, TabError::EscrowNotPending);
        require!(escrow.claim_type == ClaimType::Code, TabError::WrongClaimType);
        require!(
            Clock::get()?.unix_timestamp <= escrow.deadline,
            TabError::EscrowExpired
        );
        let computed: [u8; 32] = hashv(&[&secret]).to_bytes();
        require!(computed == escrow.commitment, TabError::CommitmentMismatch);

        _settle(
            escrow,
            &ctx.accounts.escrow_vault,
            &ctx.accounts.recipient_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }

    /// Anyone can call after the deadline. Pull pattern keeps the
    /// executor key out of the refund path. Works even while paused.
    pub fn refund(ctx: Context<Refund>) -> Result<()> {
        let escrow = &mut ctx.accounts.escrow;
        require!(escrow.status == Status::Pending, TabError::EscrowNotPending);
        require!(
            Clock::get()?.unix_timestamp > escrow.deadline,
            TabError::EscrowNotExpired
        );

        let amount = escrow.amount;
        let escrow_key = escrow.key();
        let bump = escrow.bump;
        let seeds: &[&[u8]] = &[b"escrow", escrow_key.as_ref(), &[bump]];
        let signer_seeds: &[&[&[u8]]] = &[seeds];

        transfer_checked(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from: ctx.accounts.escrow_vault.to_account_info(),
                    to: ctx.accounts.sender_ata.to_account_info(),
                    authority: escrow.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                },
                signer_seeds,
            ),
            amount,
            ctx.accounts.mint.decimals,
        )?;

        escrow.status = Status::Refunded;
        Ok(())
    }
}

/* ------------------------------ helpers ----------------------------- */

fn _create_escrow(
    ctx: Context<CreateEscrow>,
    commitment: [u8; 32],
    amount: u64,
    deadline: i64,
    sender_nonce: u64,
    claim_type: ClaimType,
) -> Result<()> {
    require!(amount > 0, TabError::InvalidAmount);
    let now = Clock::get()?.unix_timestamp;
    require!(
        deadline >= now + MIN_DEADLINE_WINDOW_SECS && deadline <= now + MAX_DEADLINE_WINDOW_SECS,
        TabError::InvalidDeadline
    );

    let escrow = &mut ctx.accounts.escrow;
    escrow.sender = ctx.accounts.sender.key();
    escrow.commitment = commitment;
    escrow.amount = amount;
    escrow.deadline = deadline;
    escrow.fee_bps_snapshot = ctx.accounts.config.fee_bps;
    escrow.claim_type = claim_type;
    escrow.status = Status::Pending;
    escrow.sender_nonce = sender_nonce;
    escrow.bump = ctx.bumps.escrow;

    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.sender_ata.to_account_info(),
                to: ctx.accounts.escrow_vault.to_account_info(),
                authority: ctx.accounts.sender.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
            },
        ),
        amount,
        ctx.accounts.mint.decimals,
    )?;

    Ok(())
}

fn _settle<'info>(
    escrow: &mut Account<'info, Escrow>,
    escrow_vault: &InterfaceAccount<'info, TokenAccount>,
    recipient_ata: &InterfaceAccount<'info, TokenAccount>,
    fee_ata: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let fee = escrow.amount * escrow.fee_bps_snapshot / BPS_DENOMINATOR;
    let net = escrow.amount - fee;

    let escrow_key = escrow.key();
    let bump = escrow.bump;
    let seeds: &[&[u8]] = &[b"escrow", escrow_key.as_ref(), &[bump]];
    let signer_seeds: &[&[&[u8]]] = &[seeds];

    if fee > 0 {
        transfer_checked(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: escrow_vault.to_account_info(),
                    to: fee_ata.to_account_info(),
                    authority: escrow.to_account_info(),
                    mint: mint.to_account_info(),
                },
                signer_seeds,
            ),
            fee,
            mint.decimals,
        )?;
    }
    transfer_checked(
        CpiContext::new_with_signer(
            token_program.to_account_info(),
            TransferChecked {
                from: escrow_vault.to_account_info(),
                to: recipient_ata.to_account_info(),
                authority: escrow.to_account_info(),
                mint: mint.to_account_info(),
            },
            signer_seeds,
        ),
        net,
        mint.decimals,
    )?;

    escrow.status = Status::Claimed;
    Ok(())
}

/* ------------------------------ accounts ---------------------------- */

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = 8 + EscrowConfig::INIT_SPACE,
        seeds = [b"escrow_config"],
        bump
    )]
    pub config: Box<Account<'info, EscrowConfig>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    /// CHECK: Just the address that will receive fees. We don't read or
    /// write to this account in initialize.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(mut, seeds = [b"escrow_config"], bump = config.bump, has_one = admin)]
    pub config: Box<Account<'info, EscrowConfig>>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(executor_key: Pubkey)]
pub struct AddExecutor<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = admin)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(
        init_if_needed,
        payer = admin,
        space = 8 + ExecutorEntry::INIT_SPACE,
        seeds = [b"executor", executor_key.as_ref()],
        bump
    )]
    pub executor: Account<'info, ExecutorEntry>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(executor_key: Pubkey)]
pub struct RemoveExecutor<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = admin)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(
        mut,
        seeds = [b"executor", executor_key.as_ref()],
        bump = executor.bump
    )]
    pub executor: Account<'info, ExecutorEntry>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(commitment: [u8; 32], amount: u64, deadline: i64, sender_nonce: u64)]
pub struct CreateEscrow<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = mint)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(
        init,
        payer = sender,
        space = 8 + Escrow::INIT_SPACE,
        seeds = [
            b"escrow",
            sender.key().as_ref(),
            &commitment,
            &sender_nonce.to_le_bytes(),
        ],
        bump
    )]
    pub escrow: Box<Account<'info, Escrow>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = sender,
    )]
    pub sender_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init,
        payer = sender,
        associated_token::mint = mint,
        associated_token::authority = escrow,
    )]
    pub escrow_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub sender: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ClaimHandle<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(mut)]
    pub escrow: Box<Account<'info, Escrow>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = escrow,
    )]
    pub escrow_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Recipient address. Must own `recipient_ata`. We don't sign
    /// for recipient here — they don't need to be present.
    pub recipient: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = executor,
        associated_token::mint = mint,
        associated_token::authority = recipient,
    )]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config. Match enforced via `has_one`.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = executor,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        seeds = [b"executor", executor.key().as_ref()],
        bump = executor_entry.bump,
        constraint = executor_entry.allowed @ TabError::NotExecutor,
    )]
    pub executor_entry: Account<'info, ExecutorEntry>,
    #[account(mut)]
    pub executor: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ClaimCode<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(mut)]
    pub escrow: Box<Account<'info, Escrow>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = escrow,
    )]
    pub escrow_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init_if_needed,
        payer = claimant,
        associated_token::mint = mint,
        associated_token::authority = claimant,
    )]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = claimant,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub claimant: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ClaimCodeFor<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(mut)]
    pub escrow: Box<Account<'info, Escrow>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = escrow,
    )]
    pub escrow_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Recipient address provided by executor. Funds go to their ATA.
    pub recipient: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = executor,
        associated_token::mint = mint,
        associated_token::authority = recipient,
    )]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = executor,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        seeds = [b"executor", executor.key().as_ref()],
        bump = executor_entry.bump,
        constraint = executor_entry.allowed @ TabError::NotExecutor,
    )]
    pub executor_entry: Account<'info, ExecutorEntry>,
    #[account(mut)]
    pub executor: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Refund<'info> {
    #[account(seeds = [b"escrow_config"], bump = config.bump, has_one = mint)]
    pub config: Box<Account<'info, EscrowConfig>>,
    #[account(mut, has_one = sender)]
    pub escrow: Box<Account<'info, Escrow>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = escrow,
    )]
    pub escrow_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Must match the escrow's sender (enforced by `has_one`).
    pub sender: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = caller,
        associated_token::mint = mint,
        associated_token::authority = sender,
    )]
    pub sender_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Anyone can pay the rent and trigger the refund — pull pattern.
    #[account(mut)]
    pub caller: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/* ------------------------------- state ------------------------------ */

#[account]
#[derive(InitSpace)]
pub struct EscrowConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub mint: Pubkey,
    pub fee_bps: u64,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Escrow {
    pub sender: Pubkey,
    pub commitment: [u8; 32],
    pub amount: u64,
    pub deadline: i64,
    /// Snapshotted at creation — later admin fee changes do not affect
    /// this escrow's settlement. Mirrors the EVM contract.
    pub fee_bps_snapshot: u64,
    pub claim_type: ClaimType,
    pub status: Status,
    pub sender_nonce: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct ExecutorEntry {
    pub allowed: bool,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum Status {
    Pending,
    Claimed,
    Refunded,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum ClaimType {
    Handle,
    Code,
}

/* ------------------------------ errors ------------------------------ */

#[error_code]
pub enum TabError {
    #[msg("Fee above 5% cap")]
    FeeAboveCap,
    #[msg("Empty commitment")]
    EmptyCommitment,
    #[msg("Invalid amount (must be > 0)")]
    InvalidAmount,
    #[msg("Deadline must be 1h-90d in the future")]
    InvalidDeadline,
    #[msg("Escrow is not pending")]
    EscrowNotPending,
    #[msg("Escrow not yet expired")]
    EscrowNotExpired,
    #[msg("Escrow expired — must refund, not claim")]
    EscrowExpired,
    #[msg("Wrong claim type — handle escrow vs code escrow mismatch")]
    WrongClaimType,
    #[msg("Commitment does not match preimage")]
    CommitmentMismatch,
    #[msg("Caller is not an authorized executor")]
    NotExecutor,
    #[msg("Program is paused")]
    Paused,
}
