// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

/// @title Tron mainnet deployment for UniversalRouter targeting SunSwap V3.
///
/// @notice This script is **not directly broadcastable via `forge script`**
/// — see item 1 below. It exists to (a) fix the deployment parameters in one
/// reviewed location and (b) produce verified artifacts under `out-tron/`
/// that the out-of-band Tron deployer (TronWeb / equivalent) consumes.
///
/// MUST be invoked under the `tron` foundry profile so that `V3SwapRouter`
/// resolves OZ's `Create2` to the `0x41`-prefix variant shipped by
/// `hyperlane-xyz/core/overrides/tron/Create2.sol`. Without that profile,
/// `computePoolAddress` produces EVM-style addresses and rejects every
/// SunSwap pool callback. Build with:
///
///   FOUNDRY_PROFILE=tron forge build
///
/// `deploy()` is overridden to revert so an accidental `forge script` does
/// not pretend to broadcast.
///
/// V2 and V4 are intentionally unsupported on Tron for v1 — `v2Factory` and
/// `v4PoolManager` are mapped to `UnsupportedProtocol` via `mapUnsupported()`.
/// V2 may be added later; SunSwap V3 holds ~70% of USDT/WTRX TVL today.
///
/// Open items before this can deploy:
///
/// 1. **`forge script --broadcast` is not viable on Tron.** Tron txs use
///    `ref_block_hash + ref_block_bytes` for replay protection, not nonces,
///    so neither Chainstack nor TronGrid expose `eth_getTransactionCount`
///    via their JSON-RPC adapters — and forge requires it. `eth_feeHistory`
///    is also missing (Tron has no EIP-1559). The deployment must be driven
///    out-of-band: a TronWeb / TronBox script reads the compiled bytecode
///    from `out-tron/` and submits Tron-native `CreateSmartContract` /
///    `TriggerSmartContract` txs to a `/wallet` REST endpoint.
///
/// 2. **CreateX is not deployed on Tron mainnet** (chain id `728126428`).
///    None of the canonical CREATE2 factories (CreateX, Arachnid's
///    deterministic deployer, Solady's `Create2Factory`, Safe's singleton
///    factory) are deployed at their EVM addresses on Tron — verified via
///    `eth_getCode`. The out-of-band deployer must either bootstrap a
///    minimal CREATE2 factory itself or use plain CREATE in a fixed
///    sequence. Cross-chain address parity is unavoidably lost since TVM
///    uses a 0x41 CREATE2 prefix.
///
/// 3. **SunSwap V3 pool init code hash.** RESOLVED. Verified empirically
///    against three live USDT/WTRX pools (fee tiers 500/3000/10000) — the
///    constant in `lib/sunswap-v3-contracts/contracts/v3-periphery/contracts
///    /libraries/PoolAddress.sol` matches all three pool addresses when used
///    with the `0x41` prefix. See `poolInitCodeHash` below.
///
/// 4. **Permit2 is not deployed on Tron.** The base script's default at
///    `0x494bbD8A3302AcA833D307D11838f18DbAdA9C25` does not exist on Tron.
///    The out-of-band deployer must deploy Permit2 first and pass its
///    address into `RouterDeployParameters.permit2`.
///
/// 5. **TVM CREATE2 prefix.** RESOLVED — see the [profile.tron] foundry
///    profile, which contextually remaps OZ's `Create2.sol` (imported by
///    `V3SwapRouter`) to `hyperlane-xyz/core`'s 0x41 override. `forge inspect`
///    confirms the substituted bytecode differs from the default profile.
///
/// 6. **Deployer must be funded.** The deployer EOA
///    `0x4994DacdB9C57A811aFfbF878D92E00EF2E5C4C2` (Tron base58:
///    derivable by prepending `0x41` and base58check-encoding) currently
///    holds 0 TRX on Tron mainnet — confirmed via `eth_getBalance`.
contract DeployTron is DeployUniversalRouter {
    error DeployTron_NotReadyToDeploy();

    function setUp() public virtual override {
        params = DeploymentParameters({
            // WTRX (`TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR`)
            weth9: 0x891cdb91d149f23B1a45D9c5Ca78a88d0cB44C18,
            // SunSwap V3 factory (`TThJt8zaJzJMhCEScH7zWKnp5buVZqys9x`).
            // Source: lib/sunswap-v3-contracts/contracts/v3-core/contracts/UniswapV3Factory.sol
            v3Factory: 0xC2708485c99cd8cF058dE1a9a7e3C2d8261a995C,
            // Verified against on-chain pools at fee tiers 500/3000/10000 with
            // the 0x41 prefix. Source: SunSwap PoolAddress.POOL_INIT_CODE_HASH.
            poolInitCodeHash: 0xba928a717d71946d75999ef1adef801a79cd34a20efecea8b2876b85f5f49580,
            // V2 unsupported on Tron for v1 — mapped to UnsupportedProtocol via mapUnsupported().
            v2Factory: address(0),
            pairInitCodeHash: bytes32(0),
            // V4 not deployed on Tron — UnsupportedProtocol via mapUnsupported().
            v4PoolManager: address(0),
            // Velodrome / Aerodrome family not deployed on Tron.
            veloV2Factory: address(0),
            veloCLFactory: address(0),
            veloV2InitCodeHash: bytes32(0),
            veloCLInitCodeHash: bytes32(0),
            veloCLFactory2: address(0),
            veloCLInitCodeHash2: bytes32(0),
            veloCLFactory3: address(0),
            veloCLInitCodeHash3: bytes32(0)
        });

        outputFilename = 'tron.json';
    }

    /// @dev Forge script broadcast is not viable on Tron — see item 1 in the
    /// contract NatSpec. This override exists purely so an accidental
    /// `forge script` does not silently pretend to deploy.
    function deploy() internal virtual override {
        revert DeployTron_NotReadyToDeploy();
    }
}
