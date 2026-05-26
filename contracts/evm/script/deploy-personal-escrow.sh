#!/usr/bin/env bash
# Personal Escrow Router deploy helper. Mirrors deploy.sh but for the
# 0%-fee TabEscrowRouter dedicated to bot-relayed P2P tips.
#
# Usage:
#   ./script/deploy-personal-escrow.sh <chain>
#
# Where <chain> is one of: base, bsc, ink, celo (the 4 mainnets that
# currently run the bot relay). Testnets supported via the same
# extended list as deploy.sh.
#
# Requires:
#   - DEPLOYER_PRIVATE_KEY  : same deployer wallet that owns the
#                             existing TabEscrowRouter on each chain.
#
# Inherited defaults (all match the canonical production deployment;
# override per-shell if you need different values):
#   - TREASURY_ADDRESS=0x16835E99977BbFdbCA7159C962586f884A41af4b
#   - EXECUTOR_ADDRESS=0xFE8f188f745b6195ba49cDBFCb4903650E2Dca70
#
# For mainnets, also: BASESCAN_API_KEY / BSCSCAN_API_KEY /
# CELOSCAN_API_KEY / INK_BLOCKSCOUT_API_KEY for --verify.

set -euo pipefail

CHAIN="${1:-}"
if [[ -z "$CHAIN" ]]; then
  echo "usage: $0 <chain>"
  echo ""
  echo "chains: base bsc ink celo  (or testnets: base-sepolia bsc-testnet ink-sepolia celo-alfajores)"
  exit 1
fi

: "${DEPLOYER_PRIVATE_KEY:?must be set in env}"

# Production defaults — confirmed against deployed-{base,bsc,ink,celo}.txt.
# Override these only if you're deploying for a different operator.
TREASURY_ADDRESS="${TREASURY_ADDRESS:-0x16835E99977BbFdbCA7159C962586f884A41af4b}"
EXECUTOR_ADDRESS="${EXECUTOR_ADDRESS:-0xFE8f188f745b6195ba49cDBFCb4903650E2Dca70}"

DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

# Per-chain RPC + stablecoin + chain-id triples. MUST match the values
# the existing TabEscrowRouter uses on each chain — same stable means
# the relayer doesn't need separate ERC-20 allowances per contract.
# Build the --verify flag only when both the API key is set AND we're
# on a chain whose explorer we want to publish to. Empty API key with
# --verify causes a hard error ("a value is required for
# --etherscan-api-key") — better to skip verification than crash the
# whole deploy. You can re-verify manually later via forge verify-contract.
build_verify_flag() {
  local key_var="$1"
  local key_val="${!key_var:-}"
  if [[ -n "$key_val" ]]; then
    VERIFY_FLAG="--verify --etherscan-api-key $key_val"
  else
    VERIFY_FLAG=""
    echo "  (skipping verification — set $key_var to verify on the explorer)"
  fi
}

case "$CHAIN" in
  base)
    RPC="${RPC_BASE:-https://mainnet.base.org}"
    STABLE="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"  # USDC
    CHAIN_ID=8453
    build_verify_flag BASESCAN_API_KEY
    ;;
  base-sepolia)
    RPC="${RPC_BASE_SEPOLIA:-https://sepolia.base.org}"
    STABLE="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    CHAIN_ID=84532
    VERIFY_FLAG=""
    ;;
  bsc)
    RPC="${RPC_BSC:-https://bsc-dataseed.binance.org}"
    STABLE="0x55d398326f99059fF775485246999027B3197955"  # USDT
    CHAIN_ID=56
    build_verify_flag BSCSCAN_API_KEY
    ;;
  bsc-testnet)
    RPC="${RPC_BSC_TESTNET:-https://data-seed-prebsc-1-s1.binance.org:8545}"
    STABLE="${STABLE_BSC_TESTNET:?must set STABLE_BSC_TESTNET}"
    CHAIN_ID=97
    VERIFY_FLAG=""
    ;;
  ink)
    RPC="${RPC_INK:-https://rpc-gel.inkonchain.com}"
    STABLE="${STABLE_INK:-0x0200C29006150606B650577BBE7B6248F58470c1}"  # USDT0
    CHAIN_ID=57073
    build_verify_flag INK_BLOCKSCOUT_API_KEY
    ;;
  ink-sepolia)
    RPC="${RPC_INK_SEPOLIA:-https://rpc-gel-sepolia.inkonchain.com}"
    STABLE="${STABLE_INK_SEPOLIA:?must set STABLE_INK_SEPOLIA}"
    CHAIN_ID=763373
    VERIFY_FLAG=""
    ;;
  celo)
    RPC="${RPC_CELO:-https://forno.celo.org}"
    STABLE="0x765DE816845861e75A25fCA122bb6898B8B1282a"  # cUSD
    CHAIN_ID=42220
    build_verify_flag CELOSCAN_API_KEY
    ;;
  celo-alfajores)
    RPC="${RPC_CELO_ALFAJORES:-https://alfajores-forno.celo-testnet.org}"
    STABLE="${STABLE_CELO_ALFAJORES:-0x874069Fa1Eb16D44d622F2e0Ca25eeA172369bC1}"
    CHAIN_ID=44787
    VERIFY_FLAG=""
    ;;
  *)
    echo "unknown chain: $CHAIN"
    exit 1
    ;;
esac

echo "================================================================"
echo "  Deploying Personal Escrow Router (0% fee) to: $CHAIN  (id=$CHAIN_ID)"
echo "  RPC:       $RPC"
echo "  Stable:    $STABLE"
echo "  Deployer:  $DEPLOYER_ADDR"
echo "  Treasury:  $TREASURY_ADDRESS"
echo "  Executor:  $EXECUTOR_ADDRESS"
echo "  Fee:       0 bps (hardcoded in DeployPersonalEscrow.s.sol)"
echo "================================================================"

STABLE_ADDRESS="$STABLE" \
TREASURY_ADDRESS="$TREASURY_ADDRESS" \
EXECUTOR_ADDRESS="$EXECUTOR_ADDRESS" \
forge script script/DeployPersonalEscrow.s.sol \
  --rpc-url "$RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  $VERIFY_FLAG \
  -vvv

echo ""
CHAIN_KEY=$(echo "$CHAIN" | tr '[:lower:]-' '[:upper:]_')
echo "Done. Set this env var in Vercel (replace 0x… with the printed address):"
echo "  NEXT_PUBLIC_TAB_ESCROW_PERSONAL_$CHAIN_KEY = 0x..."
echo ""
echo "Or set all four at once (after deploying to base, bsc, ink, celo):"
echo "  NEXT_PUBLIC_TAB_ESCROW_PERSONAL_BASE = 0x..."
echo "  NEXT_PUBLIC_TAB_ESCROW_PERSONAL_BSC  = 0x..."
echo "  NEXT_PUBLIC_TAB_ESCROW_PERSONAL_INK  = 0x..."
echo "  NEXT_PUBLIC_TAB_ESCROW_PERSONAL_CELO = 0x..."
