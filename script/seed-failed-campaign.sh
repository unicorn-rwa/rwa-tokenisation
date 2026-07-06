#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Seed a local "failed campaign" so the refund/claim UI can be tested end-to-end.
#
# It:
#   1. Deploys a fresh PropertyFunding (default 100k goal) with a SHORT deadline.
#   2. KYC-attests + invests UNDER the goal from the Anvil test wallets
#      (and your own wallet if MM_WALLET_PK is set) — so the goal can't be met.
#   3. Warps Anvil's chain time past the deadline (so triggerRefund/claimRefund work).
#   4. Prints the deployed addresses + the admin-panel fields to register it.
#
# Prereqs (you already have these):
#   - Anvil fork on $RPC_URL with Deploy.s.sol already run (factory/KYC/USDC).
#   - Backend + frontend running; test wallets funded (script/fund-wallets.sh).
#   - foundry (forge + cast) installed.
#
# Usage (from rwa/):
#   ./script/seed-failed-campaign.sh
#   MM_WALLET_PK=0x<your-wallet-key> ./script/seed-failed-campaign.sh   # also invest from your wallet
#

# Env overrides: RPC_URL, FACTORY_ADDRESS, ADMIN_PK, DEADLINE_SECONDS, WARP_SECONDS,
#                TOKEN_NAME, TOKEN_SYMBOL, FUNDING_GOAL (forwarded to PropertyDeploy).
# ─────────────────────────────────────────────────────────────────────────────

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# PropertyFundingFactory (from broadcast/Deploy.s.sol/84532/run-latest.json)
FACTORY_ADDRESS="${FACTORY_ADDRESS:-0xf53bf50346d9fd4844ecbf94bf1b26ef67ec5893}"
# Anvil account[1] — holds ADMIN_ROLE on the factory locally. PUBLIC test key.
ADMIN_PK="${ADMIN_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-120}"            # short → frontend wall clock passes it quickly
WARP_SECONDS="${WARP_SECONDS:-$((DEADLINE_SECONDS + 600))}"
TOKEN_NAME="${TOKEN_NAME:-Failing Test Campaign}"
TOKEN_SYMBOL="${TOKEN_SYMBOL:-PROP-FAIL-01}"

cd "$(dirname "$0")/.."   # → rwa/

command -v forge >/dev/null || { echo "❌ forge not found (install foundry)"; exit 1; }
command -v cast  >/dev/null || { echo "❌ cast not found (install foundry)"; exit 1; }
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null 2>&1 \
  || { echo "❌ Anvil not reachable at $RPC_URL"; exit 1; }

echo "==> Pre-building contracts (keeps the deploy/invest broadcasts fast enough for the short deadline)…"
forge build >/dev/null

NOW="$(date +%s)"
DEADLINE=$((NOW + DEADLINE_SECONDS))
echo "==> Deploying failing property (deadline in ${DEADLINE_SECONDS}s = epoch ${DEADLINE}; goal = PropertyDeploy default 100k unless FUNDING_GOAL set)…"

DEPLOY_OUT="$(DEPLOY_ENV=local FACTORY_ADDRESS="$FACTORY_ADDRESS" DEADLINE="$DEADLINE" \
  TOKEN_NAME="$TOKEN_NAME" TOKEN_SYMBOL="$TOKEN_SYMBOL" \
  forge script script/PropertyDeploy.s.sol \
    --private-key "$ADMIN_PK" --rpc-url "$RPC_URL" --broadcast -vvvv 2>&1)" \
  || { echo "❌ deploy failed:"; echo "$DEPLOY_OUT" | tail -40; exit 1; }

# PropertyDeploy.s.sol prints the three addresses as "  <Name>  : 0x…".
extract() { echo "$DEPLOY_OUT" | grep -oE "$1[[:space:]]+:[[:space:]]+0x[0-9a-fA-F]{40}" | grep -oE "0x[0-9a-fA-F]{40}" | head -1; }
FUNDING="$(extract 'PropertyFunding')"
TOKEN="$(extract 'PropertyToken')"
ROI="$(extract 'ROIDistributor')"

[ -n "$FUNDING" ] || { echo "❌ couldn't parse PropertyFunding address from deploy output:"; echo "$DEPLOY_OUT" | tail -40; exit 1; }
echo "    PropertyFunding : $FUNDING"
echo "    PropertyToken   : $TOKEN"
echo "    ROIDistributor  : $ROI"

echo "==> Investing under goal (KYC + invest from Anvil test wallets${MM_WALLET_PK:+ + your wallet})…"
if [ -n "${MM_WALLET_PK:-}" ]; then
  INVEST_OUT="$(FUNDING="$FUNDING" MM_WALLET_PK="$MM_WALLET_PK" \
    forge script script/Invest.s.sol --rpc-url "$RPC_URL" --broadcast -vvv 2>&1)" \
    || { echo "❌ invest failed:"; echo "$INVEST_OUT" | tail -40; exit 1; }
else
  INVEST_OUT="$(FUNDING="$FUNDING" \
    forge script script/Invest.s.sol --rpc-url "$RPC_URL" --broadcast -vvv 2>&1)" \
    || { echo "❌ invest failed:"; echo "$INVEST_OUT" | tail -40; exit 1; }
fi
echo "    invested ≈15–20k USDC — well under the 100k goal."

echo "==> Warping Anvil ${WARP_SECONDS}s so block.timestamp passes the deadline (for triggerRefund)…"
cast rpc evm_increaseTime "$WARP_SECONDS" --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
echo "    chain warped + mined."

READY_HUMAN="$(date -r "$DEADLINE" '+%H:%M:%S' 2>/dev/null || echo "epoch $DEADLINE")"
cat <<EOF

──────────────────────────────────────────────────────────────────────────
✅ Failed campaign seeded.

  PropertyFunding : $FUNDING
  PropertyToken   : $TOKEN
  ROIDistributor  : $ROI

1) Register it in the app — admin panel → Create property:
     name    : $TOKEN_NAME
     slug    : failing-test-campaign
     status  : FUNDRAISING
     funding : $FUNDING
     token   : $TOKEN
     roi     : $ROI
     goal    : 100000

2) CLOCK NOTE: the panel shows the failed state only once your browser's wall
   clock passes the deadline (epoch $DEADLINE ≈ $READY_HUMAN) — about
   ${DEADLINE_SECONDS}s after the deploy above. The chain is ALREADY warped past
   it, so triggerRefund / claimRefund work immediately.

3) Open the property page, connect an investor wallet:
     • your wallet (if you passed MM_WALLET_PK), or
     • an Anvil test wallet that invested, e.g. alice = Anvil[4]:
         0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
   → Start refund → Claim refund → Refund Complete.
──────────────────────────────────────────────────────────────────────────
EOF
