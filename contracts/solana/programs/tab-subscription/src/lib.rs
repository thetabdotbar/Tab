//! TabSubscription — recurring SPL token charges on Solana.
//!
//! Mirrors the EVM TabSubscriptionRouter. A creator publishes a plan
//! (amount, period, mint). Subscribers pre-approve a delegate (the
//! program's PDA) on their token account; an off-chain cron — or anyone
//! permissionlessly — calls `charge` once per period. Funds flow
//! subscriber → (creator, fee_recipient).
//!
//! Differences from EVM design (Solana-specific):
//! - Solana has no native ERC20 allowance pattern. Instead we use SPL
//!   token `approve` with a PDA delegate (the plan PDA), then the program
//!   signs as that delegate to pull funds.
//! - Subscription PDA is keyed by (plan, subscriber) so two subscribers
//!   can't collide.
//! - Per-plan fee snapshot to match EVM behavior.
//! - Pause halts new subscribe + charge; cancel always works.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

declare_id!("Ex1hBmDhmz8hZ7oYy4BKtt5jstEMCoeeshEA51swbXZa");

pub const BPS_DENOMINATOR: u64 = 10_000;
pub const MAX_FEE_BPS: u64 = 500;
pub const MIN_PERIOD_SECS: i64 = 3_600;
pub const MAX_PERIOD_SECS: i64 = 365 * 24 * 3_600;
/// PDA seed for the global spend-authority. Subscribers delegate their
/// ATA's spend authority to this pubkey via `spl-token approve` so the
/// permissionless `charge` instruction can pull funds without the
/// subscriber co-signing each period.
pub const SPEND_AUTHORITY_SEED: &[u8] = b"spend_authority";

#[program]
pub mod tab_subscription {
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

    /// Creator publishes a plan. plan_id is a creator-scoped string —
    /// the on-chain identity is the (creator, plan_id) seed pair, so
    /// different creators can use the same id without conflict.
    pub fn create_plan(
        ctx: Context<CreatePlan>,
        plan_id: String,
        amount: u64,
        period_secs: i64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(amount > 0, TabError::InvalidAmount);
        require!(
            period_secs >= MIN_PERIOD_SECS && period_secs <= MAX_PERIOD_SECS,
            TabError::InvalidPeriod
        );
        require!(plan_id.len() <= 64 && !plan_id.is_empty(), TabError::InvalidPlanId);

        let plan = &mut ctx.accounts.plan;
        plan.creator = ctx.accounts.creator.key();
        plan.amount = amount;
        plan.period_secs = period_secs;
        // Snapshot the current fee — later admin changes don't retroactively hit this plan.
        plan.fee_bps_snapshot = ctx.accounts.config.fee_bps;
        plan.active = true;
        plan.bump = ctx.bumps.plan;
        Ok(())
    }

    pub fn deactivate_plan(ctx: Context<ManagePlan>) -> Result<()> {
        require!(ctx.accounts.plan.active, TabError::PlanInactive);
        ctx.accounts.plan.active = false;
        Ok(())
    }

    pub fn reactivate_plan(ctx: Context<ManagePlan>) -> Result<()> {
        require!(!ctx.accounts.plan.active, TabError::PlanAlreadyActive);
        ctx.accounts.plan.active = true;
        Ok(())
    }

    /// Subscribe + charge the first period immediately.
    pub fn subscribe(ctx: Context<Subscribe>) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(ctx.accounts.plan.active, TabError::PlanInactive);

        let sub = &mut ctx.accounts.subscription;
        require!(!sub.active, TabError::AlreadySubscribed);

        let now = Clock::get()?.unix_timestamp;
        sub.subscriber = ctx.accounts.subscriber.key();
        sub.plan = ctx.accounts.plan.key();
        sub.active = true;
        sub.started_at = now;
        sub.last_charged_at = now;
        sub.cancelled_at = 0;
        sub.charges_paid = 1;
        sub.bump = ctx.bumps.subscription;

        _move_funds(
            &ctx.accounts.plan,
            &ctx.accounts.config,
            &ctx.accounts.subscriber_ata,
            &ctx.accounts.creator_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.subscriber,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }

    /// Cancel — always works, even while paused. Subscribers can never
    /// be locked into being billed.
    pub fn cancel(ctx: Context<Cancel>) -> Result<()> {
        let sub = &mut ctx.accounts.subscription;
        require!(sub.active, TabError::NotSubscribed);
        sub.active = false;
        sub.cancelled_at = Clock::get()?.unix_timestamp;
        Ok(())
    }

    /// Permissionless charge. Reverts with specific error so the cron
    /// can distinguish wait / cancelled / out-of-funds.
    ///
    /// The subscriber's ATA must have delegated spend authority to the
    /// `spend_authority` PDA via `spl-token approve` (either at subscribe
    /// time or any time before the first charge). The cron caller signs
    /// the tx; the PROGRAM signs the actual transfer via the PDA. No
    /// subscriber signature required — that's what makes the recurring
    /// billing work autonomously.
    pub fn charge(ctx: Context<Charge>) -> Result<()> {
        require!(!ctx.accounts.config.paused, TabError::Paused);
        require!(ctx.accounts.plan.active, TabError::PlanInactive);

        let plan = &ctx.accounts.plan;
        let sub = &mut ctx.accounts.subscription;
        require!(sub.active, TabError::NotSubscribed);

        let now = Clock::get()?.unix_timestamp;
        require!(now >= sub.last_charged_at + plan.period_secs, TabError::TooEarly);

        // Pre-flight: balance check. (Delegate-allowance check happens
        // inside the SPL transfer; if the subscriber revoked their
        // delegate the transfer reverts cleanly.)
        require!(
            ctx.accounts.subscriber_ata.amount >= plan.amount,
            TabError::InsufficientBalance
        );

        sub.last_charged_at = now;
        sub.charges_paid += 1;

        _move_funds_delegated(
            plan,
            ctx.bumps.spend_authority,
            &ctx.accounts.subscriber_ata,
            &ctx.accounts.creator_ata,
            &ctx.accounts.fee_ata,
            &ctx.accounts.spend_authority,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )
    }
}

/// First-charge-at-subscribe variant. The subscriber IS present and signs
/// the subscribe tx, so we use their authority directly. No delegate
/// dependency for this path — keeps the subscribe step simple and means
/// the subscriber can choose to delegate-or-not in a separate `approve`
/// transaction depending on whether they want auto-renewal.
fn _move_funds<'info>(
    plan: &Account<'info, Plan>,
    _config: &Account<'info, SubConfig>,
    subscriber_ata: &InterfaceAccount<'info, TokenAccount>,
    creator_ata: &InterfaceAccount<'info, TokenAccount>,
    fee_ata: &InterfaceAccount<'info, TokenAccount>,
    subscriber: &Signer<'info>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let fee = plan.amount * plan.fee_bps_snapshot / BPS_DENOMINATOR;
    let net = plan.amount - fee;

    if fee > 0 {
        transfer_checked(
            CpiContext::new(
                token_program.to_account_info(),
                TransferChecked {
                    from: subscriber_ata.to_account_info(),
                    to: fee_ata.to_account_info(),
                    authority: subscriber.to_account_info(),
                    mint: mint.to_account_info(),
                },
            ),
            fee,
            mint.decimals,
        )?;
    }
    transfer_checked(
        CpiContext::new(
            token_program.to_account_info(),
            TransferChecked {
                from: subscriber_ata.to_account_info(),
                to: creator_ata.to_account_info(),
                authority: subscriber.to_account_info(),
                mint: mint.to_account_info(),
            },
        ),
        net,
        mint.decimals,
    )?;
    Ok(())
}

/// Recurring-charge variant. The PROGRAM signs the SPL transfer via its
/// spend_authority PDA, which the subscriber pre-delegated as their
/// ATA's spend authority. The token program accepts because the ATA's
/// delegate matches the signer. Subscriber doesn't need to be present.
fn _move_funds_delegated<'info>(
    plan: &Account<'info, Plan>,
    auth_bump: u8,
    subscriber_ata: &InterfaceAccount<'info, TokenAccount>,
    creator_ata: &InterfaceAccount<'info, TokenAccount>,
    fee_ata: &InterfaceAccount<'info, TokenAccount>,
    spend_authority: &UncheckedAccount<'info>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let fee = plan.amount * plan.fee_bps_snapshot / BPS_DENOMINATOR;
    let net = plan.amount - fee;

    let bump_arr = [auth_bump];
    let seeds: &[&[u8]] = &[SPEND_AUTHORITY_SEED, &bump_arr];
    let signer_seeds: &[&[&[u8]]] = &[seeds];

    if fee > 0 {
        transfer_checked(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: subscriber_ata.to_account_info(),
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
                from: subscriber_ata.to_account_info(),
                to: creator_ata.to_account_info(),
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
        space = 8 + SubConfig::INIT_SPACE,
        seeds = [b"sub_config"], bump
    )]
    pub config: Account<'info, SubConfig>,
    pub mint: InterfaceAccount<'info, Mint>,
    /// CHECK: Fee receiver address — not read/written in initialize.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(mut, seeds = [b"sub_config"], bump = config.bump, has_one = admin)]
    pub config: Account<'info, SubConfig>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(plan_id: String)]
pub struct CreatePlan<'info> {
    #[account(seeds = [b"sub_config"], bump = config.bump)]
    pub config: Box<Account<'info, SubConfig>>,
    #[account(
        init, payer = creator,
        space = 8 + Plan::INIT_SPACE,
        seeds = [b"plan", creator.key().as_ref(), plan_id.as_bytes()], bump
    )]
    pub plan: Box<Account<'info, Plan>>,
    #[account(mut)]
    pub creator: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ManagePlan<'info> {
    #[account(mut, has_one = creator)]
    pub plan: Box<Account<'info, Plan>>,
    pub creator: Signer<'info>,
}

#[derive(Accounts)]
pub struct Subscribe<'info> {
    #[account(seeds = [b"sub_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, SubConfig>>,
    #[account(mut)]
    pub plan: Box<Account<'info, Plan>>,
    #[account(
        init, payer = subscriber,
        space = 8 + Subscription::INIT_SPACE,
        seeds = [b"sub", plan.key().as_ref(), subscriber.key().as_ref()], bump
    )]
    pub subscription: Box<Account<'info, Subscription>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = subscriber,
    )]
    pub subscriber_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Plan's creator — funds get sent here. The subscriber's
    /// client (the /subscribe page in tab-web) pre-creates the
    /// creator_ata + fee_ata before invoking this ix.
    #[account(address = plan.creator)]
    pub creator: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = creator,
    )]
    pub creator_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config (has_one).
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub subscriber: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Cancel<'info> {
    #[account(
        mut,
        seeds = [b"sub", subscription.plan.as_ref(), subscriber.key().as_ref()],
        bump = subscription.bump,
        has_one = subscriber,
    )]
    pub subscription: Box<Account<'info, Subscription>>,
    pub subscriber: Signer<'info>,
}

#[derive(Accounts)]
pub struct Charge<'info> {
    #[account(seeds = [b"sub_config"], bump = config.bump, has_one = mint, has_one = fee_recipient)]
    pub config: Box<Account<'info, SubConfig>>,
    #[account()]
    pub plan: Box<Account<'info, Plan>>,
    /// CHECK: The subscriber. Doesn't sign — `subscriber_ata` must have
    /// delegated its spend authority to `spend_authority` PDA via
    /// `spl-token approve`. The subscription PDA seeds keep things bound
    /// to this exact subscriber + plan pair.
    pub subscriber: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [b"sub", plan.key().as_ref(), subscriber.key().as_ref()],
        bump = subscription.bump,
        has_one = subscriber,
    )]
    pub subscription: Box<Account<'info, Subscription>>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = subscriber,
    )]
    pub subscriber_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Plan's creator (must match plan.creator). The cron caller
    /// is responsible for ensuring `creator_ata` exists before invoking
    /// this ix (one-time cost on first charge of each plan).
    #[account(address = plan.creator)]
    pub creator: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = creator,
    )]
    pub creator_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: Stored on config.
    pub fee_recipient: UncheckedAccount<'info>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = fee_recipient,
    )]
    pub fee_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    /// CHECK: PDA the subscriber pre-delegated as spend authority on
    /// their `subscriber_ata`. The program signs for it via seeds in
    /// the SPL transfer CPI.
    #[account(seeds = [SPEND_AUTHORITY_SEED], bump)]
    pub spend_authority: UncheckedAccount<'info>,
    /// Anyone can pay rent + trigger. This is what makes the cron
    /// permissionless — the caller just covers tx fee + any ATA rent.
    #[account(mut)]
    pub caller: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/* ------------------------------- state ------------------------------ */

#[account]
#[derive(InitSpace)]
pub struct SubConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub mint: Pubkey,
    pub fee_bps: u64,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Plan {
    pub creator: Pubkey,
    pub amount: u64,
    pub period_secs: i64,
    pub fee_bps_snapshot: u64,
    pub active: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Subscription {
    pub subscriber: Pubkey,
    pub plan: Pubkey,
    pub active: bool,
    pub started_at: i64,
    pub last_charged_at: i64,
    pub cancelled_at: i64,
    pub charges_paid: u64,
    pub bump: u8,
}

/* ------------------------------ errors ------------------------------ */

#[error_code]
pub enum TabError {
    #[msg("Fee above 5% cap")]
    FeeAboveCap,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Invalid period (must be 1h-365d)")]
    InvalidPeriod,
    #[msg("Plan id must be 1-64 chars")]
    InvalidPlanId,
    #[msg("Plan is inactive")]
    PlanInactive,
    #[msg("Plan is already active")]
    PlanAlreadyActive,
    #[msg("Already subscribed")]
    AlreadySubscribed,
    #[msg("Not subscribed")]
    NotSubscribed,
    #[msg("Too early — period hasn't elapsed")]
    TooEarly,
    #[msg("Insufficient balance")]
    InsufficientBalance,
    #[msg("Program is paused")]
    Paused,
}
