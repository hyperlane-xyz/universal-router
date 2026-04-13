// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import 'forge-std/Test.sol';

import {ICLFactory} from 'contracts/interfaces/external/ICLFactory.sol';
import {INonfungiblePositionManagerCL} from 'contracts/interfaces/external/INonfungiblePositionManager.sol';

import '../BaseForkFixture.t.sol';
import '../mock/MockERC20.sol';

abstract contract BaseMixedSlipstreamFixture is BaseForkFixture {
    // Legacy CLFactory pools
    address public poolFactory1_WETH_DAI;
    address public poolFactory1_WETH_USDT;

    // CLFactory pools
    address public poolFactory2_USDT_TOKENA;
    address public poolFactory2_TOKENA_TOKENB;

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

        // Create pools on legacy factory
        poolFactory1_WETH_DAI =
            createAndSeedPoolFactory(CL_FACTORY_BASE, address(WETH), address(DAI_BASE), TICK_SPACING);
        poolFactory1_WETH_USDT =
            createAndSeedPoolFactory(CL_FACTORY_BASE, address(WETH), address(USDT_BASE), TICK_SPACING);

        // Create pools on cl factory
        poolFactory2_USDT_TOKENA =
            createAndSeedPoolFactory(CL_FACTORY_2, address(USDT_BASE), address(tokenA), TICK_SPACING);
        poolFactory2_TOKENA_TOKENB =
            createAndSeedPoolFactory(CL_FACTORY_2, address(tokenA), address(tokenB), TICK_SPACING);

        vm.startPrank(FROM);
        deal(FROM, BALANCE);
        deal(address(WETH), FROM, BALANCE);
        deal(address(DAI_BASE), FROM, BALANCE);
        deal(address(USDT_BASE), FROM, BALANCE);
        deal(address(tokenA), FROM, BALANCE);
        deal(address(tokenB), FROM, BALANCE);
        ERC20(address(WETH)).approve(address(leafRouter), type(uint256).max);
        ERC20(address(DAI_BASE)).approve(address(leafRouter), type(uint256).max);
        ERC20(address(USDT_BASE)).approve(address(leafRouter), type(uint256).max);
        ERC20(address(tokenA)).approve(address(leafRouter), type(uint256).max);
        ERC20(address(tokenB)).approve(address(leafRouter), type(uint256).max);
    }

    function createAndSeedPoolFactory(ICLFactory poolFactory, address tokenA, address tokenB, int24 tickSpacing)
        internal
        returns (address newPool)
    {
        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        newPool = poolFactory.getPool(tokenA, tokenB, tickSpacing);
        if (newPool == address(0)) {
            newPool = poolFactory.createPool(tokenA, tokenB, tickSpacing, encodePriceSqrt(1, 1));
        }

        seedPool(poolFactory, newPool, tokenA, tokenB, tickSpacing);
    }

    function seedPool(ICLFactory poolFactory, address pool, address tokenA, address tokenB, int24 tickSpacing)
        internal
    {
        INonfungiblePositionManagerCL nft = address(poolFactory) == address(CL_FACTORY_2) ? NFT_2 : NFT_BASE;

        uint256 amountA = 5_000_000 * 10 ** ERC20(tokenA).decimals();
        uint256 amountB = 5_000_000 * 10 ** ERC20(tokenB).decimals();
        deal(tokenA, address(this), amountA);
        deal(tokenB, address(this), amountB);
        ERC20(tokenA).approve(address(pool), amountA);
        ERC20(tokenB).approve(address(pool), amountB);
        ERC20(tokenA).approve(address(nft), amountA);
        ERC20(tokenB).approve(address(nft), amountB);

        INonfungiblePositionManagerCL.MintParams memory params = INonfungiblePositionManagerCL.MintParams({
            token0: address(tokenA),
            token1: address(tokenB),
            tickSpacing: tickSpacing,
            tickLower: getMinTick(tickSpacing),
            tickUpper: getMaxTick(tickSpacing),
            recipient: FROM,
            amount0Desired: amountA,
            amount1Desired: amountB,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
        nft.mint(params);
    }

    function labelContracts() internal {
        vm.label(address(leafRouter), 'UniversalRouter');
        vm.label(RECIPIENT, 'Recipient');
        vm.label(address(CL_FACTORY_BASE), 'CL Pool Factory 1');
        vm.label(address(CL_FACTORY_2), 'CL Pool Factory 2');
        vm.label(address(NFT_BASE), 'Position Manager 1');
        vm.label(address(NFT_2), 'Position Manager 2');
        vm.label(address(WETH), 'WETH');
        vm.label(address(DAI_BASE), 'DAI_BASE');
        vm.label(address(USDT_BASE), 'USDT_BASE');
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
