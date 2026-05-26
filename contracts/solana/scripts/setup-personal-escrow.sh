#!/usr/bin/env bash
# Idempotent setup for the Personal Escrow program. Run this once
# before `anchor deploy`.
#
# What it does (in order):
#   1. Generates a program keypair if none exists at
#      target/deploy/tab_escrow_personal-keypair.json.
#   2. Prints the resulting program ID.
#   3. Runs `anchor keys sync` so the placeholder declare_id in lib.rs
#      and the placeholder address in Anchor.toml are both updated to
#      match the keypair. (Anchor 0.30+.)
#   4. Runs `anchor build` to confirm everything compiles before deploy.
#
# After this script: review the diff on Anchor.toml + lib.rs (they
# should now have a real program ID), then run:
#
#   anchor deploy --program-name tab_escrow_personal --provider.cluster mainnet
#
# Then init the program with:
#   node scripts/init-personal-escrow.mjs

set -euo pipefail

cd "$(dirname "$0")/.."

KP="target/deploy/tab_escrow_personal-keypair.json"

if [[ ! -f "$KP" ]]; then
  echo "==> Generating program keypair at $KP"
  mkdir -p "$(dirname "$KP")"
  solana-keygen new --no-bip39-passphrase --silent -o "$KP"
else
  echo "==> Keypair already exists at $KP — reusing"
fi

PROGRAM_ID=$(solana-keygen pubkey "$KP")
echo "==> tab_escrow_personal program ID: $PROGRAM_ID"

echo "==> Syncing declare_id + Anchor.toml to match the keypair"
anchor keys sync

echo "==> Building"
anchor build

echo ""
echo "Setup complete. Next steps:"
echo "  1. Confirm balance on deployer wallet: solana balance"
echo "     (need ~5 SOL for a fresh program deploy)"
echo "  2. Deploy:"
echo "     anchor deploy --program-name tab_escrow_personal --provider.cluster mainnet"
echo "  3. Initialize (creates the EscrowConfig PDA + adds executor):"
echo "     node scripts/init-personal-escrow.mjs"
echo "  4. Add the program ID to tab-web env:"
echo "     NEXT_PUBLIC_TAB_ESCROW_PERSONAL_SOLANA=$PROGRAM_ID"
