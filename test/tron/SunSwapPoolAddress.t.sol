// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';

/// @notice Locks in that the [profile.tron] foundry profile resolves
/// `Create2.computeAddress` to the 0x41-prefix variant from
/// hyperlane-xyz/core/overrides/tron/Create2.sol — verified by computing
/// real SunSwap V3 USDT/WTRX pool addresses and asserting equality.
///
/// Sources of truth (live mainnet, captured 2026-05-01):
///   factory:      TThJt8zaJzJMhCEScH7zWKnp5buVZqys9x
///   init code:    SunSwap PoolAddress.POOL_INIT_CODE_HASH
///   pools:        getPool(USDT, WTRX, fee) on factory at fee = 500/3000/10000
///
/// Run under tron profile only:
///   FOUNDRY_PROFILE=tron forge test --mp test/tron/SunSwapPoolAddress.t.sol
contract SunSwapPoolAddressTest is Test {
    address constant FACTORY = 0xC2708485c99cd8cF058dE1a9a7e3C2d8261a995C;
    address constant WTRX = 0x891cdb91d149f23B1a45D9c5Ca78a88d0cB44C18;
    address constant USDT = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    bytes32 constant POOL_INIT_CODE_HASH = 0xba928a717d71946d75999ef1adef801a79cd34a20efecea8b2876b85f5f49580;

    // token0 < token1 lexicographically: WTRX (0x89...) < USDT (0xa6...)
    address constant TOKEN0 = WTRX;
    address constant TOKEN1 = USDT;

    address constant POOL_FEE_500 = 0xB50B027637ab9a7F2ba5B70a24f778F8438bb279;
    address constant POOL_FEE_3000 = 0x17dE3C58e08f09B3b1D0f3D5FB163FBeB3d826Cd;
    address constant POOL_FEE_10000 = 0x907C0E95509ae158690Eda213e1F01521DD0dE88;

    function _computePool(uint24 fee) internal pure returns (address) {
        return Create2.computeAddress({
            salt: keccak256(abi.encode(TOKEN0, TOKEN1, fee)),
            bytecodeHash: POOL_INIT_CODE_HASH,
            deployer: FACTORY
        });
    }

    function test_computesLiveSunSwapPool_fee500() public pure {
        assertEq(_computePool(500), POOL_FEE_500);
    }

    function test_computesLiveSunSwapPool_fee3000() public pure {
        assertEq(_computePool(3000), POOL_FEE_3000);
    }

    function test_computesLiveSunSwapPool_fee10000() public pure {
        assertEq(_computePool(10000), POOL_FEE_10000);
    }
}
