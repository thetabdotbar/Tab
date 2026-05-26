#!/usr/bin/env bash
# Multi-chain deploy helper. Usage:
#   ./script/deploy.sh <chain>
# Where <chain> is one of: base, base-sepolia, bsc, bsc-testnet, ink,
# ink-sepolia, celo, celo-alfajores.
#
# Requires:
#   - DEPLOYER_PRIVATE_KEY in env (the wallet that will own + treasury the routers)
#   - Optionally EXECUTOR_ADDRESS in env (defaults to deployer's address for TabBotRouter)
#   - For mainnets you may also want BASESCAN_API_KEY / BSCSCAN_API_KEY / CELOSCAN_API_KEY / etc. for --verify

set -euo pipefail

CHAIN="${1:-}"
if [[ -z "$CHAIN" ]]; then
  echo "usage: $0 <chain>"
  echo ""
  echo "chains: base base-sepolia bsc bsc-testnet ink ink-sepolia celo celo-alfajores"
  exit 1
fi

: "${DEPLOYER_PRIVATE_KEY:?must be set in env}"

# Default treasury + executor to the deployer's address derived via cast.
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
TREASURY_ADDRESS="${TREASURY_ADDRESS:-$DEPLOYER_ADDR}"
EXECUTOR_ADDRESS="${EXECUTOR_ADDRESS:-$DEPLOYER_ADDR}"
ROUTER_FEE_BPS="${ROUTER_FEE_BPS:-100}"
BOT_FEE_BPS="${BOT_FEE_BPS:-100}"
ESCROW_FEE_BPS="${ESCROW_FEE_BPS:-100}"
SUB_FEE_BPS="${SUB_FEE_BPS:-100}"

# Per-chain RPC + stablecoin + chain-id triples.
case "$CHAIN" in
  base)
    RPC="${RPC_BASE:-https://mainnet.base.org}"
    STABLE="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"  # USDC
    CHAIN_ID=8453
    VERIFY_FLAG="--verify --etherscan-api-key ${BASESCAN_API_KEY:-}"
    ;;
  base-sepolia)
    RPC="${RPC_BASE_SEPOLIA:-https://sepolia.base.org}"
    STABLE="0x036CbD53842c5426634e7929541eC2318f3dCF7e"  # USDC testnet
    CHAIN_ID=84532
    VERIFY_FLAG=""
    ;;
  bsc)
    RPC="${RPC_BSC:-https://bsc-dataseed.binance.org}"
    STABLE="0x55d398326f99059fF775485246999027B3197955"  # USDT
    CHAIN_ID=56
    VERIFY_FLAG="--verify --etherscan-api-key ${BSCSCAN_API_KEY:-}"
    ;;
  bsc-testnet)
    RPC="${RPC_BSC_TESTNET:-https://data-seed-prebsc-1-s1.binance.org:8545}"
    STABLE="${STABLE_BSC_TESTNET:?must set STABLE_BSC_TESTNET — no canonical testnet USDT}"
    CHAIN_ID=97
    VERIFY_FLAG=""
    ;;
  ink)
    RPC="${RPC_INK:-https://rpc-gel.inkonchain.com}"
    # USDT0 — verify against Tether's official deploy table.
    STABLE="${STABLE_INK:-0x0200C29006150606B650577BBE7B6248F58470c1}"
    CHAIN_ID=57073
    VERIFY_FLAG="--verify --etherscan-api-key ${INK_BLOCKSCOUT_API_KEY:-}"
    ;;
  ink-sepolia)
    RPC="${RPC_INK_SEPOLIA:-https://rpc-gel-sepolia.inkonchain.com}"
    STABLE="${STABLE_INK_SEPOLIA:?must set STABLE_INK_SEPOLIA — no canonical testnet USDT0}"
    CHAIN_ID=763373
    VERIFY_FLAG=""
    ;;
  celo)
    RPC="${RPC_CELO:-https://forno.celo.org}"
    STABLE="0x765DE816845861e75A25fCA122bb6898B8B1282a"  # cUSD (Mento)
    CHAIN_ID=42220
    VERIFY_FLAG="--verify --etherscan-api-key ${CELOSCAN_API_KEY:-}"
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
echo "  Deploying Tab to: $CHAIN  (id=$CHAIN_ID)"
echo "  RPC:       $RPC"
echo "  Stable:    $STABLE"
echo "  Deployer:  $DEPLOYER_ADDR"
echo "  Treasury:  $TREASURY_ADDRESS"
echo "  Executor:  $EXECUTOR_ADDRESS"
echo "  Bot fee:    $BOT_FEE_BPS bps"
echo "  Escrow fee: $ESCROW_FEE_BPS bps"
echo "  Sub fee:    $SUB_FEE_BPS bps"
echo "================================================================"

STABLE_ADDRESS="$STABLE" \
TREASURY_ADDRESS="$TREASURY_ADDRESS" \
EXECUTOR_ADDRESS="$EXECUTOR_ADDRESS" \
ROUTER_FEE_BPS="$ROUTER_FEE_BPS" \
BOT_FEE_BPS="$BOT_FEE_BPS" \
ESCROW_FEE_BPS="$ESCROW_FEE_BPS" \
SUB_FEE_BPS="$SUB_FEE_BPS" \
forge script script/Deploy.s.sol \
  --rpc-url "$RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  $VERIFY_FLAG \
  -vvv

echo ""
# Frontend env vars use UPPER_SNAKE_CASE chain keys.
CHAIN_KEY=$(echo "$CHAIN" | tr '[:lower:]-' '[:upper:]_')
echo "Done. Set these env vars in Vercel (replace 0x… with the printed addresses):"
echo "  NEXT_PUBLIC_TAB_ROUTER_$CHAIN_KEY              = 0x..."
echo "  NEXT_PUBLIC_TAB_BOT_ROUTER_$CHAIN_KEY          = 0x..."
echo "  NEXT_PUBLIC_TAB_ESCROW_ROUTER_$CHAIN_KEY       = 0x..."
echo "  NEXT_PUBLIC_TAB_SUBSCRIPTION_ROUTER_$CHAIN_KEY = 0x..."
