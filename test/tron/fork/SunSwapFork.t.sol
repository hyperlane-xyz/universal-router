// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from 'forge-std/Test.sol';
import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';
import {ICLPool} from 'contracts/interfaces/external/ICLPool.sol';

/// @notice Empirical fork tests against live Tron mainnet via TronGrid.
/// Run with:
///   FOUNDRY_PROFILE=tron forge test --mp test/tron/fork/SunSwapFork.t.sol -vvv
///
/// These tests exercise increasing levels of fidelity:
///   1. View-only: factory.getPool, pool.slot0/token0/token1/fee/liquidity
///   2. State-mutating: try to actually execute a swap on a forked pool
///
/// Goal is to find out empirically what the fork can and cannot do.
interface IFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUSDT {
    function balanceOf(address) external view returns (uint256);
}

interface IFullPool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16 observationCardinality, uint16 observationCardinalityNext,
        uint8 feeProtocol, bool unlocked
    );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract SunSwapForkTest is Test {
    string constant TRON_RPC = 'https://api.trongrid.io/jsonrpc';
    address constant FACTORY = 0xC2708485c99cd8cF058dE1a9a7e3C2d8261a995C;
    address constant WTRX = 0x891cdb91d149f23B1a45D9c5Ca78a88d0cB44C18;
    address constant USDT = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    address constant POOL_500 = 0xB50B027637ab9a7F2ba5B70a24f778F8438bb279;

    function setUp() public {
        vm.createSelectFork(TRON_RPC);
    }

    function test_fork_chainId() public view {
        assertEq(block.chainid, 728126428, 'expected Tron mainnet chainid');
    }

    function test_fork_factory_getPool() public view {
        address pool = IFactory(FACTORY).getPool(USDT, WTRX, 500);
        assertEq(pool, POOL_500, 'factory.getPool returned unexpected address');
    }

    function test_fork_pool_state() public view {
        IFullPool pool = IFullPool(POOL_500);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint128 liq = pool.liquidity();
        console.log('sqrtPriceX96:', sqrtPriceX96);
        console.log('liquidity:', liq);
        assertGt(sqrtPriceX96, 0, 'pool sqrtPriceX96 should be non-zero');
        assertGt(liq, 0, 'pool liquidity should be non-zero');
    }

    function test_fork_pool_balances() public view {
        uint256 usdtBal = IUSDT(USDT).balanceOf(POOL_500);
        console.log('Pool USDT balance:', usdtBal);
        assertGt(usdtBal, 1e6, 'pool USDT balance should be >$1');
    }

    /// @notice Try to execute a real swap on the forked pool.
    /// This is a flash-style swap: pool calls back uniswapV3SwapCallback,
    /// the test contract (msg.sender) must transfer tokenIn during callback.
    /// Setup: vm.store USDT balance into the test contract, approve nothing
    /// (USDT is not used directly — pool pulls via callback).
    function test_fork_pool_swap_execute() public {
        // Sanity: this test contract starts with 0 USDT
        uint256 usdtBefore = IUSDT(USDT).balanceOf(address(this));

        // Forge USDT balance for this test contract.
        // USDT (TRC20) typically stores balance at slot keccak256(addr | mappingSlot).
        // We don't know the exact slot offhand; use deal() which uses slot detection.
        deal(USDT, address(this), 1000e6); // 1000 USDT
        uint256 usdtAfterDeal = IUSDT(USDT).balanceOf(address(this));
        console.log('USDT before deal:', usdtBefore);
        console.log('USDT after deal:', usdtAfterDeal);
        require(usdtAfterDeal == 1000e6, 'deal() did not set USDT balance');

        // Now try a small swap: USDT -> WTRX, exactInput 100 USDT
        IFullPool pool = IFullPool(POOL_500);
        // token0 < token1 means: token0 = WTRX, token1 = USDT.
        // We're swapping USDT (token1) for WTRX (token0), so zeroForOne = false.
        bool zeroForOne = false;
        int256 amountSpecified = int256(uint256(100e6)); // 100 USDT
        // Use max sqrt ratio bound for one-way trade
        uint160 sqrtPriceLimitX96 = 1461446703485210103287273052203988822378723970341; // MAX_SQRT_RATIO - 1

        uint256 wtrxBefore = IERC20Min(WTRX).balanceOf(address(this));
        try pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, '') {
            uint256 wtrxAfter = IERC20Min(WTRX).balanceOf(address(this));
            console.log('Swap succeeded! WTRX received:', wtrxAfter - wtrxBefore);
        } catch Error(string memory reason) {
            console.log('Swap reverted with reason:', reason);
            revert(reason);
        } catch (bytes memory data) {
            console.log('Swap reverted with raw data:');
            console.logBytes(data);
            revert('Swap reverted');
        }
    }

    /// @notice Pool callback — must pay tokenIn back to the pool.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL_500, 'callback: unexpected caller');
        // We're swapping USDT (token1) for WTRX (token0). amount1Delta > 0 means we owe USDT.
        if (amount1Delta > 0) {
            IERC20Min(USDT).transfer(msg.sender, uint256(amount1Delta));
        } else if (amount0Delta > 0) {
            IERC20Min(WTRX).transfer(msg.sender, uint256(amount0Delta));
        }
    }
}
