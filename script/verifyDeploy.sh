#!/bin/bash

# Post-deploy verification for UniversalRouter.
# Runs fork tests that check on-chain immutables and bytecode against local artifacts.
#
# Usage:
#   ./script/verifyDeploy.sh base optimism    # verify specific chains
#   ./script/verifyDeploy.sh --all            # verify all chains

set -e

# ── Supported chains ─────────────────────────────────────────────────────────
CHAINS=(
    base
    celo
    fraxtal
    ink
    lisk
    metal
    mode
    optimism
    soneium
    superseed
    swell
    unichain
)

# ── Helpers ──────────────────────────────────────────────────────────────────
to_pascal() {
    echo "$(echo "${1:0:1}" | tr '[:lower:]' '[:upper:]')${1:1}"
}

is_valid_chain() {
    local name=$1
    for c in "${CHAINS[@]}"; do
        [[ "$c" == "$name" ]] && return 0
    done
    return 1
}

usage() {
    echo "Usage: $0 <chain ...> | --all"
    echo ""
    echo "Examples:"
    echo "  $0 base optimism        # verify Base and Optimism"
    echo "  $0 --all                # verify all chains"
    echo ""
    echo "Supported chains: ${CHAINS[*]}"
    exit 1
}

# ── Parse args ───────────────────────────────────────────────────────────────
if [ "$#" -lt 1 ]; then
    usage
fi

targets=()

if [ "$1" == "--all" ]; then
    targets=("${CHAINS[@]}")
else
    for arg in "$@"; do
        if ! is_valid_chain "$arg"; then
            echo "Error: unknown chain '$arg'"
            echo "Supported chains: ${CHAINS[*]}"
            exit 1
        fi
        targets+=("$arg")
    done
fi

# ── Run ──────────────────────────────────────────────────────────────────────
failed=()

for chain in "${targets[@]}"; do
    pascal=$(to_pascal "$chain")
    contract="VerifyDeploy${pascal}"

    echo "── Verifying ${chain} (${contract}) ──"

    if forge test --match-contract "$contract" --fork-url "$chain" -vvv; then
        echo "OK: ${chain}"
    else
        echo "FAIL: ${chain}"
        failed+=("$chain")
    fi

    echo ""
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════"
echo "Verified ${#targets[@]} chain(s), ${#failed[@]} failure(s)"

if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    exit 1
fi
