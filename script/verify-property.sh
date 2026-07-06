#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Verify a property's 3 contracts (PropertyToken, PropertyFunding, ROIDistributor)
# on Basescan.
#
# These are deployed by the factory *inside* createProject (PropertyFunding via a
# delegatecall to the deployer library), so `forge script --verify` skips them.
# This reconstructs each contract's constructor args from on-chain reads + the one
# value that isn't readable (spvAdmin) and submits a verification for each.
#
# Usage (from rwa/):
#   FUNDING=0x<PropertyFunding> \
#   SPV_ADMIN=0x<spvAdmin used at createProject> \
#   FACTORY_ADDRESS=0x9822861d8A41b655aa0C0DF79017299F6283A28E \
#   BASESCAN_API_KEY=$BASESCAN_API_KEY \
#   ./script/verify-property.sh
#
# Optional: RPC_URL (default Base Sepolia public), CHAIN_ID (default 84532),
#           DRY_RUN=1  → print the resolved args + verify commands, don't submit.
# ─────────────────────────────────────────────────────────────────────────────

RPC_URL="${RPC_URL:-https://sepolia.base.org}"
CHAIN_ID="${CHAIN_ID:-84532}"
DRY_RUN="${DRY_RUN:-0}"

: "${FUNDING:?set FUNDING=0x<PropertyFunding address>}"
: "${SPV_ADMIN:?set SPV_ADMIN=0x<spvAdmin passed at createProject>}"
: "${FACTORY_ADDRESS:?set FACTORY_ADDRESS=0x<factory>}"
[ "$DRY_RUN" = "1" ] || : "${BASESCAN_API_KEY:?set BASESCAN_API_KEY (or DRY_RUN=1)}"

command -v cast >/dev/null  || { echo "❌ cast not found";  exit 1; }
command -v forge >/dev/null || { echo "❌ forge not found"; exit 1; }

# cast prints uints as "123 [1.2e2]" and strings quoted — normalise both.
cu() { cast call "$1" "$2" --rpc-url "$RPC_URL" | awk '{print $1}'; }              # uint / address
cs() { cast call "$1" "$2" --rpc-url "$RPC_URL" | sed 's/^"//; s/"$//'; }          # string

# ── Resolve addresses + constructor values from chain ────────────────────────
TOKEN=$(cu "$FUNDING" "propertyToken()(address)")
ROI=$(cu "$FACTORY_ADDRESS" "projectDistributor(address)(address)" 2>/dev/null || true)
[ -n "${ROI:-}" ] && [ "$ROI" != "0x0000000000000000000000000000000000000000" ] \
  || ROI=$(cast call "$FACTORY_ADDRESS" "projectDistributor(address)(address)" "$FUNDING" --rpc-url "$RPC_URL" | awk '{print $1}')

USDC=$(cu "$FUNDING" "usdc()(address)")
KYC=$(cu "$FUNDING" "kycRegistry()(address)")
TREASURY=$(cu "$FUNDING" "withdrawalRecipient()(address)")
GOAL=$(cu "$FUNDING" "fundingGoal()(uint256)")
DEADLINE=$(cu "$FUNDING" "deadline()(uint256)")
ROIBPS=$(cu "$FUNDING" "expectedROIBps()(uint256)")
ESTART=$(cu "$FUNDING" "estimatedStartDate()(uint256)")
EEND=$(cu "$FUNDING" "estimatedEndDate()(uint256)")
MIN=$(cu "$FUNDING" "minInvestment()(uint256)")
MAXACC=$(cu "$FUNDING" "maxAccreditedInvestment()(uint256)")
MAXNON=$(cu "$FUNDING" "maxNonAccreditedUSInvestment()(uint256)")
DOC=$(cs "$FUNDING" "offeringDocHash()(string)")
NAME=$(cs "$TOKEN" "name()(string)")
SYMBOL=$(cs "$TOKEN" "symbol()(string)")

# projectDistributor takes an arg — fix the ROI read (the guard above may have run the no-arg form)
ROI=$(cast call "$FACTORY_ADDRESS" "projectDistributor(address)(address)" "$FUNDING" --rpc-url "$RPC_URL" | awk '{print $1}')

echo "── resolved ──"
printf "  PropertyToken   : %s  (%s / %s)\n" "$TOKEN" "$NAME" "$SYMBOL"
printf "  PropertyFunding : %s\n" "$FUNDING"
printf "  ROIDistributor  : %s\n" "$ROI"
printf "  usdc=%s kyc=%s spvAdmin=%s spvTreasury=%s\n" "$USDC" "$KYC" "$SPV_ADMIN" "$TREASURY"
printf "  goal=%s deadline=%s roiBps=%s min=%s maxAcc=%s maxNon=%s\n" "$GOAL" "$DEADLINE" "$ROIBPS" "$MIN" "$MAXACC" "$MAXNON"
echo ""

# ── ABI-encode each constructor's args ───────────────────────────────────────
# PropertyToken(name, symbol, admin=spvAdmin, minter=factory)
TOKEN_ARGS=$(cast abi-encode "constructor(string,string,address,address)" "$NAME" "$SYMBOL" "$SPV_ADMIN" "$FACTORY_ADDRESS")
# PropertyFunding(usdc, token, kyc, withdrawalRecipient=treasury, admin=spvAdmin, goal, deadline, roiBps, start, end, min, maxAcc, maxNon, doc)
FUNDING_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,string)" \
  "$USDC" "$TOKEN" "$KYC" "$TREASURY" "$SPV_ADMIN" "$GOAL" "$DEADLINE" "$ROIBPS" "$ESTART" "$EEND" "$MIN" "$MAXACC" "$MAXNON" "$DOC")
# ROIDistributor(admin=treasury, usdc, project=funding)
ROI_ARGS=$(cast abi-encode "constructor(address,address,address)" "$TREASURY" "$USDC" "$FUNDING")

verify() { # <address> <path:contract> <ctor-args-hex>
  echo "── verifying $2 @ $1 ──"
  if [ "$DRY_RUN" = "1" ]; then
    echo "forge verify-contract --chain $CHAIN_ID --etherscan-api-key \$BASESCAN_API_KEY --watch \\"
    echo "  --constructor-args $3 \\"
    echo "  $1 $2"
  else
    forge verify-contract --chain "$CHAIN_ID" --etherscan-api-key "$BASESCAN_API_KEY" --watch \
      --constructor-args "$3" "$1" "$2"
  fi
  echo ""
}

verify "$TOKEN"   "src/PropertyToken.sol:PropertyToken"     "$TOKEN_ARGS"
verify "$FUNDING" "src/PropertyFunding.sol:PropertyFunding" "$FUNDING_ARGS"
verify "$ROI"     "src/ROIDistributor.sol:ROIDistributor"   "$ROI_ARGS"

echo "✅ done${DRY_RUN:+ (dry run — nothing submitted)}"
