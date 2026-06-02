#!/bin/bash

# Simulate or broadcast UniversalRouter deployment for every configured chain.
#
# Usage:
#   ./script/deployAll.sh
#   ./script/deployAll.sh --broadcast
#   ./script/deployAll.sh --broadcast --with-gas-price 1000000000

set -e

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

failed=()

for chain in "${CHAINS[@]}"; do
    echo "-- Deploying ${chain} --"

    if ./script/deploy.sh "$chain" "$@"; then
        echo "OK: ${chain}"
    else
        echo "FAIL: ${chain}"
        failed+=("$chain")
    fi

    echo ""
done

echo "======================================"
echo "Processed ${#CHAINS[@]} chain(s), ${#failed[@]} failure(s)"

if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    exit 1
fi
