#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fund-wallets.sh
#
# Funds test wallets with USDC on a local Anvil fork.
#
# Strategy: Circle's USDC (FiatToken) has a masterMinter that can configure
# any address as a minter. We impersonate the masterMinter, configure our
# deployer wallet as a minter, then mint USDC directly to each test wallet.
# This works on any fork of Base Sepolia or Base mainnet.
#
# Prerequisites:
#   - Anvil running with a Base fork:
#       anvil --fork-url https://sepolia.base.org --state state/base-fork.json
#   - Wallets imported via import-wallets.sh
#
# Usage:
#   ./script/fund-wallets.sh [sepolia|mainnet]   (default: sepolia)
#
# Amounts funded:
#   alice     — $30k  (cap is $25k, fund above so we can test the limit)
#   bob       — $200k (Reg S, no cap)
#   dave      — $5k   (cap is $2.5k, fund above so we can test the limit)
#   investor5 — $50k
#   investor6 — $50k
# ---------------------------------------------------------------------------

set -e

RPC_URL="http://localhost:8545"

NETWORK="${1:-sepolia}"

if [ "$NETWORK" = "mainnet" ]; then
    USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    echo "Network: Base mainnet fork"
else
    USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    echo "Network: Base Sepolia fork"
fi

# ── Deterministic Anvil addresses + keys (from well-known mnemonic) ────────
# These are PUBLIC test keys — local dev only, never use on mainnet.
DEPLOYER="0xf39Fd6e51aad88ce6aB8827279cffFb92266"
DEPLOYER_KEY="0x238ff944bacbed5efcae784d7bf4f2ff80"
ALICE="0x15d34AAf54267DB7D7c339AAf71A00a2C6A65"
BOB="0x9965507D1a55bcC26a16FB37d819B0A4dc"
DAVE="0x976EA74026E726B657fA54763abd0C3a0aa9"
INVESTOR5="0x23618e81E3f5cdF7f54C3d65B21E8f"
INVESTOR6="0xa0Ee7A142d267C1f3675612F20a79720"

# ── USDC amounts (6 decimals) ──────────────────────────────────────────────
MINT_ALLOWANCE=999999999000000   # ~$1B — enough for all mints
ALICE_AMOUNT=30000000000         # $30k
BOB_AMOUNT=200000000000          # $200k
DAVE_AMOUNT=5000000000           # $5k
INVESTOR_AMOUNT=50000000000      # $50k each

# ── Step 1: get masterMinter from USDC contract ────────────────────────────
echo ""
echo "Fetching masterMinter from USDC contract..."
MASTER_MINTER=$(cast call "$USDC" "masterMinter()(address)" --rpc-url "$RPC_URL")
echo "  masterMinter: $MASTER_MINTER"

# ── Step 2: fund masterMinter with ETH for gas (it has 0 ETH on the fork) ─
echo ""
echo "Funding masterMinter with ETH for gas..."
cast rpc anvil_setBalance "$MASTER_MINTER" "0x56BC75E2D63100000" --rpc-url "$RPC_URL" > /dev/null
echo "  ok"

# ── Step 3: impersonate masterMinter ──────────────────────────────────────
echo "Impersonating masterMinter..."
cast rpc anvil_impersonateAccount "$MASTER_MINTER" --rpc-url "$RPC_URL" > /dev/null

# ── Step 4: configure deployer as minter ──────────────────────────────────
echo "Configuring deployer as USDC minter..."
cast send "$USDC" \
    "configureMinter(address,uint256)" \
    "$DEPLOYER" "$MINT_ALLOWANCE" \
    --from "$MASTER_MINTER" \
    --unlocked \
    --rpc-url "$RPC_URL" \
    > /dev/null

# ── Step 5: stop impersonating ─────────────────────────────────────────────
cast rpc anvil_stopImpersonatingAccount "$MASTER_MINTER" --rpc-url "$RPC_URL" > /dev/null
echo "  done."

# ── Step 6: mint USDC to each investor wallet ──────────────────────────────
mint_usdc() {
    local name=$1
    local address=$2
    local amount=$3
    local human=$(echo "scale=0; $amount / 1000000" | bc)
    echo "Minting \$$human USDC → $name ($address)"
    cast send "$USDC" \
        "mint(address,uint256)" \
        "$address" "$amount" \
        --private-key "$DEPLOYER_KEY" \
        --rpc-url "$RPC_URL" \
        > /dev/null
    echo "  ok"
}

echo ""
echo "Minting USDC..."
echo ""
mint_usdc alice     "$ALICE"     "$ALICE_AMOUNT"
mint_usdc bob       "$BOB"       "$BOB_AMOUNT"
mint_usdc dave      "$DAVE"      "$DAVE_AMOUNT"
mint_usdc investor5 "$INVESTOR5" "$INVESTOR_AMOUNT"
mint_usdc investor6 "$INVESTOR6" "$INVESTOR_AMOUNT"

# ── Step 7: verify balances ────────────────────────────────────────────────
echo ""
echo "USDC balances:"
balance() {
    local name=$1
    local address=$2
    local raw=$(cast call "$USDC" "balanceOf(address)(uint256)" "$address" --rpc-url "$RPC_URL" | awk '{print $1}')
    local human=$(echo "scale=2; $raw / 1000000" | bc)
    echo "  $name: \$$human"
}

balance alice     "$ALICE"
balance bob       "$BOB"
balance dave      "$DAVE"
balance investor5 "$INVESTOR5"
balance investor6 "$INVESTOR6"

echo ""
echo "Done. Wallets are funded and ready."
