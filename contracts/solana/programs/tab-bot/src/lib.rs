//! TabBot — bot-driven SPL payments on Solana.
//!
//! Mirrors the EVM TabBotRouter:
//! - `execute_p2p` — executor moves `amount` from a payer to a recipient
//!   based on an off-chain social command (Telegram / Discord / Farcaster
//!   message id used as dedup key).
//! - `execute_grant` — executor distributes a grant from a campaign
//!   sponsor to a recipient. One grant per (campaign_id, recipient).
//!
//! Trust model: the payer (P2P) / sponsor (grant) sets a one-time SPL
//! token delegate on their ATA, pointing to this program's deterministic
//! `spend_authority` PDA. The executor then submits txs signed only by
//! itself; the program signs the actual SPL transfers via the PDA so
//! the token program accepts them (delegate authority match).
//!
//! How to enable on Solana:
//!   spl-token approve <USDC_ATA> <amount> --delegate <SPEND_AUTH_PDA>
//!
//! Revoke at any time via:
//!   spl-token revoke <USDC_ATA>
//!
//! Per-tweet / per-grant dedup PDAs provide replay protection.
//!
//! Pause halts new P2P + grant executions. Users can revoke their token
//! delegate at any time from their wallet — funds are never trapped.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

declare_id!("42aU1kQzoXhyPcXb67qrPvQX1Tzx3Uyw4XbfUNF6nEZ8");

pub const BPS_DENOMINATOR: u64 = 10_000;
pub const MAX_FEE_BPS: u64 = 500;
/// PDA seed for the global spend-authority. One per program, all users
/// delegate to this single pubkey via `spl-token approve`. Hardcoded so
/// the on-chain ATA delegate field reads stably across clients.
pub const SPEND_AUTHORITY_SEED: &[u8] = b"spend_authority";

#[program]
pub mod tab_bot {
    use super::*;

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
        let e = &mut ctx.accounts.executor;
        e.allowed = true;
        e.bump = ctx.bumps.executor;
        Ok(())
    }

    pub fn remove_executor(ctx: Context<RemoveExecutor>) -> Result<()> {
        ctx.accounts.executor.allowed = false;
        Ok(())
    }

    /// Executor-driven P2P payment.
    ///
    /// Requires the payer to have previously delegated spend authority to
    /// `spend_authority` PDA via `spl-token approve`. The executor signs
    /// the tx; the program signs the underlying SPL transfer via the PDA
    /// (which the token program accepts because the ATA's delegate ==
    /// PDA).
    ///
    /// Dedup: `tweet_id` is hashed into a dedup PDA; reuse reverts.
    pub fn execute_p2p(
        ctx: Context<ExecuteP2p>,
        amount: u64,
        tweet_id: String,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(amount > 0, TabError::InvalidAmount);
        require!(!tweet_id.is_empty() && tweet_id.len() <= 128, TabError::InvalidId);

        let dedup = &mut ctx.accounts.tweet_dedup;
        dedup.used = true;
        dedup.bump = ctx.bumps.tweet_dedup;

        _split_transfer_delegated(
            amount,
            ctx.accounts.config.fee_bps,
            ctx.bumps.spend_authority,
            &ctx.accounts.payer_ata,
            &ctx.accounts.recipient_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.spend_authority,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }

    /// Executor-driven grant payment.
    ///
    /// Same delegated-authority model as `execute_p2p`. Sponsor must have
    /// delegated spend authority to the `spend_authority` PDA. Dedup by
    /// (campaign_id, recipient) — same campaign can't double-pay one
    /// recipient.
    pub fn execute_grant(
        ctx: Context<ExecuteGrant>,
        amount: u64,
        campaign_id: String,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(amount > 0, TabError::InvalidAmount);
        require!(!campaign_id.is_empty() && campaign_id.len() <= 64, TabError::InvalidId);

        let dedup = &mut ctx.accounts.grant_dedup;
        dedup.used = true;
        dedup.bump = ctx.bumps.grant_dedup;

        _split_transfer_delegated(
            amount,
            ctx.accounts.config.fee_bps,
            ctx.bumps.spend_authority,
            &ctx.accounts.sponsor_ata,
            &ctx.accounts.recipient_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.spend_authority,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }
}

/// PDA-signed split transfer. The PDA was previously delegated as the
/// source ATA's spending authority via `spl-token approve`, so the token
/// program accepts the transfer once the PDA signs via seeds.
fn _split_transfer_delegated<'info>(
    amount: u64,
    fee_bps: u64,
    auth_bump: u8,
    source_ata: &InterfaceAccount<'info, TokenAccount>,
    recipient_ata: &InterfaceAccount<'info, TokenAccount>,
    fee_ata: &InterfaceAccount<'info, TokenAccount>,
    spend_authority: &UncheckedAccount<'info>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let fee = amount * fee_bps / BPS_DENOMINATOR;
    let net = amount - fee;

    let bump_arr = [auth_bump];
    let seeds: &[&[u8]] = &[SPEND_AUTHORITY_SEED, &bump_arr];
    let signer_seeds: &[&[&[u8]]] = &[seeds];

    if fee > 0 {
        transfer_checked(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: source_ata.to_account_info(),
                    to: fee_ata.to_account_info(),
                    authority: spend_authority.to_account_info(),
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
                from: source_ata.to_account_info(),
                to: recipient_ata.to_account_info(),
                authority: spend_authority.to_account_info(),
                mint: mint.to_account_info(),
            },
            signer_seeds,
        ),
        net,
        mint.decimals,
    )?;
    Ok(())
}

/* ------------------------------ accounts ---------------------------- */

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init, payer = admin,
        space = 8 + BotConfig::INIT_SPACE,
        seeds = [b"bot_config"], bump
    )]
    pub config: Account<'info, BotConfig>,
    pub mint: InterfaceAccount<'info, Mint>,
    /// CHECK: Fee receiver address.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(mut, seeds = [b"bot_config"], bump = config.bump, has_one = admin)]
    pub config: Account<'info, BotConfig>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(executor_key: Pubkey)]
pub struct AddExecutor<'info> {
    #[account(seeds = [b"bot_config"], bump = config.bump, has_one = admin)]
    pub config: Account<'info, BotConfig>,
    #[account(
        init_if_needed, payer = admin,
        space = 8 + ExecutorEntry::INIT_SPACE,
        seeds = [b"executor", executor_key.as_ref()], bump
    )]
    pub executor: Account<'info, ExecutorEntry>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(executor_key: Pubkey)]
pub struct RemoveExecutor<'info> {
    #[account(seeds = [b"bot_config"], bump = config.bump, has_one = admin)]
    pub config: Account<'info, BotConfig>,
    #[account(mut, seeds = [b"executor", executor_key.as_ref()], bump = executor.bump)]
    pub executor: Account<'info, ExecutorEntry>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(amount: u64, tweet_id: String)]
pub struct ExecuteP2p<'info> {
    #[account(seeds = [b"bot_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, BotConfig>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    /// CHECK: The payer being charged. Doesn't need to sign — their
    /// payer_ata must have delegated spend authority to `spend_authority`.
    pub payer: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = payer,
    )]
    pub payer_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Recipient address. The executor pre-creates `recipient_ata`
    /// via `getOrCreateAssociatedTokenAccount` before invoking this ix,
    /// so we don't bear init_if_needed's stack overhead here.
    pub recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = recipient,
    )]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: PDA the payer pre-delegated as spend authority on their
    /// `payer_ata`. We sign for it via seeds in the CPI — no read/write
    /// on this account directly, just signing capacity.
    #[account(seeds = [SPEND_AUTHORITY_SEED], bump)]
    pub spend_authority: UncheckedAccount<'info>,
    /// init = "first use of this tweet_id"; replay reverts on duplicate.
    #[account(
        init, payer = executor,
        space = 8 + Dedup::INIT_SPACE,
        seeds = [b"tweet", anchor_lang::solana_program::hash::hash(tweet_id.as_bytes()).to_bytes().as_ref()],
        bump
    )]
    pub tweet_dedup: Box<Account<'info, Dedup>>,
    #[account(
        seeds = [b"executor", executor.key().as_ref()],
        bump = executor_entry.bump,
        constraint = executor_entry.allowed @ TabError::NotExecutor,
    )]
    pub executor_entry: Box<Account<'info, ExecutorEntry>>,
    #[account(mut)]
    pub executor: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(amount: u64, campaign_id: String)]
pub struct ExecuteGrant<'info> {
    #[account(seeds = [b"bot_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, BotConfig>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    /// CHECK: Sponsor whose ATA pays the grant. No signature required —
    /// must have delegated to `spend_authority`.
    pub sponsor: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = sponsor,
    )]
    pub sponsor_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Recipient address. Executor pre-creates `recipient_ata`.
    pub recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = recipient,
    )]
    pub recipient_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Global spend-authority PDA, see ExecuteP2p.
    #[account(seeds = [SPEND_AUTHORITY_SEED], bump)]
    pub spend_authority: UncheckedAccount<'info>,
    /// Dedup by (campaign_id, recipient) — same campaign can't double-pay same person.
    #[account(
        init, payer = executor,
        space = 8 + Dedup::INIT_SPACE,
        seeds = [
            b"grant",
            anchor_lang::solana_program::hash::hash(campaign_id.as_bytes()).to_bytes().as_ref(),
            recipient.key().as_ref(),
        ],
        bump
    )]
    pub grant_dedup: Box<Account<'info, Dedup>>,
    #[account(
        seeds = [b"executor", executor.key().as_ref()],
        bump = executor_entry.bump,
        constraint = executor_entry.allowed @ TabError::NotExecutor,
    )]
    pub executor_entry: Box<Account<'info, ExecutorEntry>>,
    #[account(mut)]
    pub executor: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/* ------------------------------- state ------------------------------ */

#[account]
#[derive(InitSpace)]
pub struct BotConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub mint: Pubkey,
    pub fee_bps: u64,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct ExecutorEntry {
    pub allowed: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Dedup {
    pub used: bool,
    pub bump: u8,
}

/* ------------------------------ errors ------------------------------ */

#[error_code]
pub enum TabError {
    #[msg("Fee above 5% cap")]
    FeeAboveCap,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Invalid id (must be 1-128 chars)")]
    InvalidId,
    #[msg("Caller is not an authorized executor")]
    NotExecutor,
    #[msg("Program is paused")]
    Paused,
}
