#!/usr/bin/env bash
# Multi-chain v2 deploy helper. Same shape as deploy.sh, but runs the
# DeployV2.s.sol script which only deploys the two updated routers
# (TabEscrowRouter + TabSubscriptionRouter). The unchanged v1 contracts
# (TabRouter, TabBotRouter) stay at their existing addresses.
#
# Usage:
#   ./script/deploy-v2.sh <chain>
# Where <chain> is one of: base, base-sepolia, bsc, bsc-testnet, ink,
# ink-sepolia, celo, celo-alfajores.
#
# Requires:
#   - V2_DEPLOYER_PRIVATE_KEY in env. MUST be a FRESH wallet with zero
#     prior history on every target chain — that's what gives the
#     deployed contracts identical addresses across all four chains
#     (the deployer's nonce starts at 0 everywhere; first contract goes
#     to the nonce-0 address, second to nonce-1, both addresses
#     deterministic from (deployer, nonce)).
#   - TREASURY_ADDRESS in env (where platform fees land)
#   - EXECUTOR_ADDRESS in env (defaults to 0xFE8f188f745b6195ba49cDBFCb4903650E2Dca70 — the prod executor)
#   - For mainnets: BASESCAN_API_KEY / BSCSCAN_API_KEY / CELOSCAN_API_KEY / INK_BLOCKSCOUT_API_KEY for --verify

set -euo pipefail

CHAIN="${1:-}"
if [[ -z "$CHAIN" ]]; then
  echo "usage: $0 <chain>"
  echo ""
  echo "chains: base base-sepolia bsc bsc-testnet ink ink-sepolia celo celo-alfajores"
  exit 1
fi

: "${V2_DEPLOYER_PRIVATE_KEY:?must be set in env — use a FRESH wallet with no prior history on any chain}"
: "${TREASURY_ADDRESS:?must be set in env}"

# Default the executor to the production executor address. Pass
# EXECUTOR_ADDRESS in env to override (e.g. on testnets you might want
# the deployer to also be the executor for quick iteration).
EXECUTOR_ADDRESS="${EXECUTOR_ADDRESS:-0xFE8f188f745b6195ba49cDBFCb4903650E2Dca70}"
ESCROW_FEE_BPS="${ESCROW_FEE_BPS:-100}"
SUB_FEE_BPS="${SUB_FEE_BPS:-100}"

V2_DEPLOYER_ADDR=$(cast wallet address --private-key "$V2_DEPLOYER_PRIVATE_KEY")

# Sanity check: the v2 deployer must be a fresh wallet. If it has any
# nonce on this chain, addresses won't match across chains.
case "$CHAIN" in
  base)
    RPC="${RPC_BASE:-https://mainnet.base.org}"
    STABLE="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"  # USDC
    VERIFY_FLAG="--verify --etherscan-api-key ${BASESCAN_API_KEY:-}"
    ;;
  base-sepolia)
    RPC="${RPC_BASE_SEPOLIA:-https://sepolia.base.org}"
    STABLE="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    VERIFY_FLAG=""
    ;;
  bsc)
    RPC="${RPC_BSC:-https://bsc-dataseed.binance.org}"
    STABLE="0x55d398326f99059fF775485246999027B3197955"  # USDT
    VERIFY_FLAG="--verify --etherscan-api-key ${BSCSCAN_API_KEY:-}"
    ;;
  bsc-testnet)
    RPC="${RPC_BSC_TESTNET:-https://data-seed-prebsc-1-s1.binance.org:8545}"
    STABLE="${STABLE_BSC_TESTNET:?must set STABLE_BSC_TESTNET}"
    VERIFY_FLAG=""
    ;;
  ink)
    RPC="${RPC_INK:-https://rpc-gel.inkonchain.com}"
    STABLE="${STABLE_INK:-0x0200C29006150606B650577BBE7B6248F58470c1}"  # USDT0
    VERIFY_FLAG="--verify --etherscan-api-key ${INK_BLOCKSCOUT_API_KEY:-}"
    ;;
  ink-sepolia)
    RPC="${RPC_INK_SEPOLIA:-https://rpc-gel-sepolia.inkonchain.com}"
    STABLE="${STABLE_INK_SEPOLIA:?must set STABLE_INK_SEPOLIA}"
    VERIFY_FLAG=""
    ;;
  celo)
    RPC="${RPC_CELO:-https://forno.celo.org}"
    STABLE="0x765DE816845861e75A25fCA122bb6898B8B1282a"  # cUSD
    VERIFY_FLAG="--verify --etherscan-api-key ${CELOSCAN_API_KEY:-}"
    ;;
  celo-alfajores)
    RPC="${RPC_CELO_ALFAJORES:-https://alfajores-forno.celo-testnet.org}"
    STABLE="${STABLE_CELO_ALFAJORES:-0x874069Fa1Eb16D44d622F2e0Ca25eeA172369bC1}"
    VERIFY_FLAG=""
    ;;
  *)
    echo "unknown chain: $CHAIN"
    exit 1
    ;;
esac

# Pre-flight nonce check. A non-zero nonce means addresses won't align.
CURRENT_NONCE=$(cast nonce "$V2_DEPLOYER_ADDR" --rpc-url "$RPC" 2>/dev/null || echo "?")
if [[ "$CURRENT_NONCE" != "0" && "$CURRENT_NONCE" != "?" ]]; then
  echo "WARNING: V2_DEPLOYER nonce on $CHAIN is $CURRENT_NONCE (expected 0)."
  echo "Contracts on this chain will NOT share addresses with chains where the nonce is still 0."
  echo "Either use a different fresh wallet, or be OK with mismatched addresses across chains."
  read -p "Continue anyway? (y/N) " yn
  case "$yn" in
    [Yy]*) ;;
    *) exit 1 ;;
  esac
fi

echo "================================================================"
echo "  Deploying Tab GASLESS V2 to: $CHAIN"
echo "  RPC:       $RPC"
echo "  Stable:    $STABLE"
echo "  Deployer:  $V2_DEPLOYER_ADDR (nonce=$CURRENT_NONCE)"
echo "  Treasury:  $TREASURY_ADDRESS"
echo "  Executor:  $EXECUTOR_ADDRESS"
echo "  Escrow fee: $ESCROW_FEE_BPS bps"
echo "  Sub fee:    $SUB_FEE_BPS bps"
echo "================================================================"

STABLE_ADDRESS="$STABLE" \
TREASURY_ADDRESS="$TREASURY_ADDRESS" \
EXECUTOR_ADDRESS="$EXECUTOR_ADDRESS" \
ESCROW_FEE_BPS="$ESCROW_FEE_BPS" \
SUB_FEE_BPS="$SUB_FEE_BPS" \
forge script script/DeployV2.s.sol \
  --rpc-url "$RPC" \
  --private-key "$V2_DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  $VERIFY_FLAG \
  -vvv

echo ""
echo "Done. Copy the two printed addresses into tab-web/lib/contracts.ts:"
echo "  DEPLOYED_TAB_ESCROW_ROUTER       = 0x..."
echo "  DEPLOYED_TAB_SUBSCRIPTION_ROUTER = 0x..."
echo ""
echo "Then set NEXT_PUBLIC_GASLESS_V2=true on Vercel and redeploy tab-web."
