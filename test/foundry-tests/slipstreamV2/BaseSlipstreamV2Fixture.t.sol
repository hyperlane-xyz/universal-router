// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import 'forge-std/Test.sol';

import {INonfungiblePositionManagerCL} from 'contracts/interfaces/external/INonfungiblePositionManager.sol';

import '../BaseForkFixture.t.sol';
import '../mock/MockERC20.sol';

abstract contract BaseSlipstreamV2Fixture is BaseForkFixture {
    address public pool; // first hop
    address public pool2; // second hop

    // Mock tokens for to avoid collisions with old factory pools
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    function setUp() public virtual override {
        leafForkBlockNumber = 36954000; //cl factory creation on base - 36953918
        super.setUp();
        vm.selectFork({forkId: leafId});

        // Deploy mock tokens
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        labelContracts();

        pool = createAndSeedPool(address(WETH), address(tokenA), TICK_SPACING);
        pool2 = createAndSeedPool(address(WETH), address(tokenB), TICK_SPACING);

        vm.startPrank(FROM);
        deal(FROM, BALANCE);
        deal(address(WETH), FROM, BALANCE);
        deal(address(tokenA), FROM, BALANCE);
        deal(address(tokenB), FROM, BALANCE);
        ERC20(address(WETH)).approve(address(leafRouter), type(uint256).max);
        ERC20(address(tokenA)).approve(address(leafRouter), type(uint256).max);
    }

    function createAndSeedPool(address tokenA, address tokenB, int24 tickSpacing) internal returns (address newPool) {
        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        newPool = CL_FACTORY_2.getPool(tokenA, tokenB, tickSpacing);
        if (newPool == address(0)) {
            newPool = CL_FACTORY_2.createPool(tokenA, tokenB, tickSpacing, encodePriceSqrt(1, 1));
        }

        // less of A
        uint256 amountA = 5_000_000 * 10 ** ERC20(tokenA).decimals();
        uint256 amountB = 5_000_000 * 10 ** ERC20(tokenB).decimals();
        deal(tokenA, address(this), amountA);
        deal(tokenB, address(this), amountB);
        ERC20(tokenA).approve(address(newPool), amountA);
        ERC20(tokenB).approve(address(newPool), amountB);
        ERC20(tokenA).approve(address(NFT_2), amountA);
        ERC20(tokenB).approve(address(NFT_2), amountB);

        INonfungiblePositionManagerCL.MintParams memory params = INonfungiblePositionManagerCL.MintParams({
            token0: address(tokenA),
            token1: address(tokenB),
            tickSpacing: TICK_SPACING,
            tickLower: getMinTick(TICK_SPACING),
            tickUpper: getMaxTick(TICK_SPACING),
            recipient: FROM,
            amount0Desired: amountA,
            amount1Desired: amountB,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
        NFT_2.mint(params);
    }

    function labelContracts() internal {
        vm.label(address(leafRouter), 'UniversalRouter');
        vm.label(RECIPIENT, 'Recipient');
        vm.label(address(CL_FACTORY_2), 'CL Pool Factory 2');
        vm.label(address(NFT_2), 'Position Manager 2');
        vm.label(address(WETH), 'WETH');
        vm.label(address(tokenA), 'TokenA');
        vm.label(address(tokenB), 'TokenB');
        vm.label(FROM, 'from');
    }

    function encodePriceSqrt(uint256 reserve1, uint256 reserve0) public pure returns (uint160) {
        reserve1 = reserve1 * 2 ** 192;
        uint256 division = reserve1 / reserve0;
        uint256 sqrtX96 = sqrt(division);

        return SafeCast.toUint160(sqrtX96);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function getMinTick(int24 tickSpacing) public pure returns (int24) {
        return (-887272 / tickSpacing) * tickSpacing;
    }

    function getMaxTick(int24 tickSpacing) public pure returns (int24) {
        return (887272 / tickSpacing) * tickSpacing;
    }
}
