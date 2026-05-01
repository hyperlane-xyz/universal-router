// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

/// @title Tron mainnet deployment for UniversalRouter targeting SunSwap V3.
///
/// @notice MUST be invoked under the `tron` foundry profile so that
/// `V3SwapRouter` resolves OZ's `Create2` to the `0x41`-prefix variant
/// shipped by `hyperlane-xyz/core/overrides/tron/Create2.sol`. Without that
/// profile, `computePoolAddress` produces EVM-style addresses and rejects
/// every SunSwap pool callback. Run as:
///
///   FOUNDRY_PROFILE=tron forge script script/deployParameters/DeployTron.s.sol
///
/// `deploy()` is overridden to revert until the CreateX/Permit2 prerequisites
/// (items 1 and 3 below) are addressed, so an accidental `forge script` does
/// not broadcast.
///
/// V2 and V4 are intentionally unsupported on Tron for v1 — `v2Factory` and
/// `v4PoolManager` are mapped to `UnsupportedProtocol` via `mapUnsupported()`.
/// V2 may be added later; SunSwap V3 holds ~70% of USDT/WTRX TVL today.
///
/// Open items before this can deploy:
///
/// 1. **CreateX is not deployed on Tron.** The base `DeployUniversalRouter`
///    deploys via `cx.deployCreate3(...)` against the canonical CreateX at
///    `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`. That contract does not
///    exist on Tron mainnet (chain id `728126428`). Recommended path: override
///    `deploy()` here to use a one-shot CREATE2 from a deterministic deployer
///    EOA. Loses cross-chain address parity but unblocks shipping.
///
/// 2. **SunSwap V3 pool init code hash.** RESOLVED. Verified empirically
///    against three live USDT/WTRX pools (fee tiers 500/3000/10000) — the
///    constant in `lib/sunswap-v3-contracts/contracts/v3-periphery/contracts
///    /libraries/PoolAddress.sol` matches all three pool addresses when used
///    with the `0x41` prefix. See `poolInitCodeHash` below.
///
/// 3. **Permit2 is not deployed on Tron.** The base script's default at
///    `0x494bbD8A3302AcA833D307D11838f18DbAdA9C25` does not exist on Tron.
///    Either deploy Permit2 separately and override `permit2` here, or have
///    the deployment script deploy it as a prerequisite.
///
/// 4. **TVM CREATE2 prefix.** RESOLVED — see the [profile.tron] foundry
///    profile, which contextually remaps OZ's `Create2.sol` (imported by
///    `V3SwapRouter`) to `hyperlane-xyz/core`'s 0x41 override. `forge inspect`
///    confirms the substituted bytecode differs from the default profile.
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

    /// @dev Disabled until items 1 and 3 above are resolved. See contract NatSpec.
    function deploy() internal virtual override {
        revert DeployTron_NotReadyToDeploy();
    }
}
