# Tab Solana programs

Anchor workspace. Six programs deployed on Solana mainnet-beta.

## Program IDs

| Program | ID |
|---|---|
| tab_router | `DvS3eW3GJGVJrvqMBtcsS8QtNoxzYtpB61Cx19Uz86xs` |
| tab_bot | `42aU1kQzoXhyPcXb67qrPvQX1Tzx3Uyw4XbfUNF6nEZ8` |
| tab_escrow | `FTpukPZPKix4N6Po8obUTwnDvyMqwAqo4EaDFyCnJjMd` |
| tab_escrow_personal | `A583E27BuN3YWP5WmsoFeaYdPtnKMAGU7tHgMrZbqwn` |
| tab_subscription | `Ex1hBmDhmz8hZ7oYy4BKtt5jstEMCoeeshEA51swbXZa` |
| tab_subscription_personal | `DpQSpSdnwRB1p7iK1b5TbL1F5YqtimGd9g32jWc4WyB7` |

## Verify on Solscan

Click any ID above on [solscan.io](https://solscan.io/) and inspect the on-chain program. The IDL extracted from compiled bytecode should match `programs/<name>/src/lib.rs`.

## What each program does

- **tab_router** — merchant checkouts on Solana. 1% platform fee.
- **tab_bot** — gasless bot tips. Spend authority pattern: user approves the bot PDA once, bot can charge up to the cap per call.
- **tab_escrow** — share-link escrows.
- **tab_escrow_personal** — relay escrows (used when bot tips an unlinked user). 0% fee.
- **tab_subscription** — recurring billing plans.
- **tab_subscription_personal** — personal recurring billing.

## Build

```bash
anchor build
anchor test
```

Built artifacts land in `target/deploy/`. The compiled bytecode hash should match what's on-chain at each program ID.

## Mirrors EVM architecture

The Solana programs mirror the EVM router architecture one-for-one. Same business logic, different signing model (Ed25519 + Anchor PDA on Solana, EIP-712 on EVM). See [../evm/](../evm/) for the EVM side.
