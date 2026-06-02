// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import './BaseMixedSlipstreamFixture.t.sol';

contract MixedSlipstreamNoPermit2Test is BaseMixedSlipstreamFixture {
    // Path: weth -> factory1 -> usdt -> factory2 -> tokenA
    function testMixedPathFactory1ToFactory2() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));

        bytes memory path =
            abi.encodePacked(address(WETH), TICK_SPACING, address(USDT_BASE), TICK_SPACING_WITH_FLAG, address(tokenA));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        leafRouter.execute(commands, inputs);

        assertEq(WETH.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(USDT_BASE.balanceOf(FROM), BALANCE);
        assertGt(tokenA.balanceOf(FROM), BALANCE);
    }

    // Path: tokenA -> factory2 -> usdt -> factory1 -> weth
    function testMixedPathFactory2ToFactory1() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));

        bytes memory path =
            abi.encodePacked(address(tokenA), TICK_SPACING_WITH_FLAG, address(USDT_BASE), TICK_SPACING, address(WETH));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        leafRouter.execute(commands, inputs);

        assertEq(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(USDT_BASE.balanceOf(FROM), BALANCE);
        assertGt(WETH.balanceOf(FROM), BALANCE);
    }

    // Path: weth -> factory1 -> usdt -> factory2 -> tokenA -> factory2 -> tokenB
    function testMultiHopMixedPathFactory1ToFactory2() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));

        bytes memory path = abi.encodePacked(
            address(WETH),
            TICK_SPACING,
            address(USDT_BASE),
            TICK_SPACING_WITH_FLAG,
            address(tokenA),
            TICK_SPACING_WITH_FLAG,
            address(tokenB)
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        leafRouter.execute(commands, inputs);

        assertEq(WETH.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(USDT_BASE.balanceOf(FROM), BALANCE);
        assertEq(tokenA.balanceOf(FROM), BALANCE);
        assertGt(tokenB.balanceOf(FROM), BALANCE);
    }

    // Path: tokenA -> factory2 -> usdt -> factory1 -> weth -> factory1 -> dai
    function testMultiHopMixedPathFactory2ToFactory1() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));

        bytes memory path = abi.encodePacked(
            address(tokenA),
            TICK_SPACING_WITH_FLAG,
            address(USDT_BASE),
            TICK_SPACING,
            address(WETH),
            TICK_SPACING,
            address(DAI_BASE)
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        leafRouter.execute(commands, inputs);

        assertEq(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(USDT_BASE.balanceOf(FROM), BALANCE);
        assertEq(WETH.balanceOf(FROM), BALANCE);
        assertGt(DAI_BASE.balanceOf(FROM), BALANCE);
    }
}
