#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Fund Base Sepolia test-investor wallets with MockUSDC (+ optional gas ETH).
#
# For each wallet you pass, it:
#   1. mints test USDC STRAIGHT to that wallet (MockUSDC has a free public mint —
#      minting to the recipient is "mint + send" in one tx), and
#   2. optionally tops it up with a little Sepolia ETH so it can approve/invest.
#
# All txs are signed & paid by DEPLOYER_PK (must already hold Sepolia ETH).
# KYC is SEPARATE — attest these wallets via Coinbase EAS / the app's verify flow
# (or a manual issueAttestation) before invest() will succeed.
#
# Usage (from rwa/):
#   DEPLOYER_PK=0x<deployer-key-with-sepolia-eth> \
#   USDC_ADDRESS=0x318000a409150E024b93BdA56f2fA91593Ce3199 \
#   ./script/fund-sepolia-investors.sh 0xWallet1 0xWallet2 0xWallet3
#
# Optional env overrides:
#   RPC_URL      chain endpoint            (default https://sepolia.base.org)
#   USDC_AMOUNT  per wallet, 6-dec integer (default 1000000000000 = $1,000,000)
#   ETH_AMOUNT   per wallet gas, in wei    (default 0.01 ETH; set 0 to skip)
# ─────────────────────────────────────────────────────────────────────────────

RPC_URL="${RPC_URL:-https://sepolia.base.org}"
USDC_AMOUNT="${USDC_AMOUNT:-1000000000000}"       # $1,000,000 (USDC has 6 decimals)
ETH_AMOUNT="${ETH_AMOUNT:-10000000000000000}"     # 0.01 ETH in wei; "0" to skip

: "${DEPLOYER_PK:?set DEPLOYER_PK=0x<deployer key that holds Sepolia ETH>}"
: "${USDC_ADDRESS:?set USDC_ADDRESS=0x<MockUSDC address>}"

command -v cast >/dev/null || { echo "❌ cast not found (install foundry)"; exit 1; }
[ "$#" -ge 1 ] || { echo "❌ pass at least one investor wallet address as an argument"; exit 1; }

DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"
echo "Deployer    : $DEPLOYER"
echo "USDC (mock) : $USDC_ADDRESS"
echo "RPC         : $RPC_URL"
echo "Per wallet  : USDC=$USDC_AMOUNT (6-dec) | ETH=$ETH_AMOUNT wei"
echo ""

# ── Sanity checks ───────────────────────────────────────────────────────────
[ "$(cast code "$USDC_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ] \
  || { echo "❌ no contract at USDC_ADDRESS on this RPC — check the address/network"; exit 1; }

BAL="$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")"
echo "Deployer ETH: $(cast from-wei "$BAL") ETH"
[ "$BAL" != "0" ] || { echo "❌ deployer has 0 ETH — fund it from a Base Sepolia faucet first"; exit 1; }
echo ""

# Fetch the deployer's next nonce ONCE and increment it locally per tx. Public RPCs
# (sepolia.base.org) are load-balanced / eventually-consistent, so looking the nonce up
# per tx can hit a lagging node and race → "nonce too low". Managing it locally gives
# each tx a deterministic, sequential nonce.
NONCE="$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")"
echo "Starting nonce: $NONCE"
echo ""

# ── Fund each wallet ────────────────────────────────────────────────────────
for W in "$@"; do
  if [[ ! "$W" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "⚠  skipping invalid address: $W"; continue
  fi
  echo "── $W ──"

  # 1) mint MockUSDC directly to the wallet (public mint; deployer pays gas)
  cast send "$USDC_ADDRESS" "mint(address,uint256)" "$W" "$USDC_AMOUNT" \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" --nonce "$NONCE" >/dev/null
  echo "   minted USDC  (nonce $NONCE)"
  NONCE=$((NONCE + 1))

  # 2) optional gas top-up so the wallet can send approve/invest txs
  if [ "$ETH_AMOUNT" != "0" ]; then
    cast send "$W" --value "$ETH_AMOUNT" \
      --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" --nonce "$NONCE" >/dev/null
    echo "   sent gas ETH (nonce $NONCE)"
    NONCE=$((NONCE + 1))
  fi
done

# Read balances at the END (after txs settle) so a lagging node doesn't show stale 0s.
echo ""
echo "── final balances ──"
for W in "$@"; do
  [[ "$W" =~ ^0x[0-9a-fA-F]{40}$ ]] || continue
  echo "  $W  USDC=$(cast call "$USDC_ADDRESS" "balanceOf(address)(uint256)" "$W" --rpc-url "$RPC_URL")  ETH=$(cast from-wei "$(cast balance "$W" --rpc-url "$RPC_URL")")"
done

echo ""
echo "✅ Done — wallets funded with test USDC${ETH_AMOUNT:+ + gas ETH}."
echo "   Next: KYC them (Coinbase EAS → app verify flow, or a manual issueAttestation),"
echo "   then they can invest on the property page."
